"""Test-only TCP proxy that delays HTTP/2 end-of-stream frames, without TLS."""
import socket
import socketserver
import threading
import time


def copy_requests(source, destination):
    try:
        while data := source.recv(65536):
            destination.sendall(data)
        destination.shutdown(socket.SHUT_WR)
    except OSError:
        pass  # Either peer may close during normal test cleanup.


class StreamEndProxy:
    def __init__(self, upstream_port, delay=0.5):
        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                with socket.create_connection(('127.0.0.1', upstream_port)) as upstream:
                    requests = threading.Thread(target=copy_requests,
                                                args=(self.request, upstream), daemon=True)
                    requests.start()
                    try:
                        with upstream.makefile('rb') as responses:
                            while header := responses.read(9):
                                if len(header) != 9:
                                    raise EOFError('truncated HTTP/2 frame header')
                                payload = responses.read(int.from_bytes(header[:3], 'big'))
                                if len(payload) != int.from_bytes(header[:3], 'big'):
                                    raise EOFError('truncated HTTP/2 frame payload')
                                # DATA/HEADERS with END_STREAM, not SETTINGS ACK.
                                # The server has already ended the RPC; let the
                                # client finish processing its last signal first.
                                if header[3] in (0, 1) and header[4] & 1:
                                    time.sleep(delay)
                                self.request.sendall(header + payload)
                    except OSError:
                        pass

        self.server = socketserver.ThreadingTCPServer(('127.0.0.1', 0), Handler)
        self.server.daemon_threads = True
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever,
                                       kwargs={'poll_interval': 0.01}, daemon=True)
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
