# 調査と実装の判断（2026-10-29）

## Dorado接続

一次資料: [ONT Dorado Basecall Server](https://nanoporetech.com/software/other/dorado-basecall-server)。確認時の掲載版は7.13.6（2026-04-29）。同ページはclient/server方式の製品で、使用文書が配布物のREADMEに入ると説明している。通常の `dorado basecaller` CLIが汎用ストリーミングRPCサーバーを提供すると仮定していない。

導入して実際に調べたAPIは `ont-pybasecall-client-lib==7.13.6` の `PyBasecallClient` と `helper_functions.package_read`。シグネチャ・docstring・実際のpackage_read出力を確認し、テストでも公式serializerを使用した。サーバーバイナリ・モデル・GPUは用意できておらず、connect以降の実サーバーとの互換性を保証する実験はできていない。

[readfishのDoradoプラグイン](https://github.com/LooseLab/readfish/blob/main/src/readfish/plugins/dorado.py) と [設定文書](https://github.com/LooseLab/readfish/blob/main/docs/toml.md) の実装を確認した。公式clientで raw int16、DAQ offset/scaling、sample rate、read startを渡す経路がある。7.13.6の `pyclient.py` を再確認し、`pass_reads` のFalseは `queue_full` に対応すると確認した。0.2.0ではこの場合を即時エラーとし、そのreadを温存する。アダプター自身の再送は行わず、次のjobには新しい接続を使う。split結果の配列を連結すると存在しない接合配列を作るため、Evidenceで分離を保つ。

Crystalから独自wire protocolを再実装するより、公式clientへの薄いstdioアダプターを採用した。アダプターは常駐し、毎回のPython起動を避ける。JSONメタデータの後にADCバイト列を送り、base64化しない。workerごとにクライアントを持ち、同じclientを複数スレッドから同時操作しない。送信IDは毎回新しいUUIDで、信号prefixの再basecallと元のMinKNOW read IDを混同しない。

追加調査では、公式の旧 [pyguppyclient](https://github.com/nanoporetech/pyguppyclient) にFlatBuffers生成コード、ZeroMQ通信、監視proxyが公開されていることを確認した。「公開の手掛かりがない」という判断は誤りだった。一方、この旧protocol 7のコードから現行7.13.6サーバーとの互換性を検証したわけではない。公開Dorado本体にもbasecalling用C++ APIはあるが、既存Basecall Server互換クライアントがそのまま得られるわけではない。今回の完成版では利用者の希望に従い、Pythonを採用し、プロトコル再実装を必須条件から外した。

公式の [PyPI説明](https://pypi.org/project/ont-pybasecall-client-lib/7.13.6/) はclient/serverのバージョン完全一致を要求している。配布物では版を固定し、接続診断とrun開始ログに実際のクライアント版を残す。これをサーバー版そのものの取得・確認とはみなさない。

## 並列マッピングと状態管理

一次資料: [minimap2](https://github.com/lh3/minimap2)、同梱v2.31の `minimap.h`、[minimap2-cr](https://github.com/kojix2/minimap2-cr) の `aligner.cr`。固定版はdependencies.jsonに記録。

minimap2のC APIは入力indexを読み取り用に共有できるが、`mm_tbuf_t`はスレッドごとに分離する必要がある。採用bindingはmap呼び出しごとにtbufを確保・破棄しているため、その経路を使用した。index生成はライブstream開始前に一度だけ行う。単なるfiber数増加でCPU並列を実現できるとは仮定せず、Crystal 1.22の `Fiber::ExecutionContext::Parallel` を使用した。

同bindingはmultipart indexをロードし、各partのmapping一覧を結合するが、全part共通のMAPQを再計算しない。閾値判定の誤りを避けるため、起動時にmultipartを拒否する。パフォーマンスは実参照・実信号・GPUを含む系全体で測る必要があり、言語の通信性能だけから実用性を結論しない。

一次資料: [minknow Crystal binding](https://github.com/kojix2/minknow)、[read_until](https://github.com/kojix2/read_until)、[ONT minknow_api](https://github.com/nanoporetech/minknow_api)。read_untilの設定・raw種別・stream modeとMinKNOWの生成済みgRPC型を利用する。累積prefixの保持と厳密な操作管理が必要なので、汎用Session内部のデフォルトバッファ挙動には依存せず、小さいcoordinatorを実装した。

保持対象はチャネルごとの現在のread世代と、上限のある処理中job。worker完了順はread順とは限らない。結果の適用時にchannel / read ID / generation / 終端状態 / deadlineを再確認する。採用枠の予約、ackによる確定と取消をcoordinatorに集め、並列workerで共有カウンタを書き換えない。

## arbitrary adaptive samplingの範囲

BEDは判定インターフェースに含めない。sequence、mapping座標・strand・CIGAR、prefix長、チャネル、read ID、read局所状態とrun内の採用数をCrystalコードへ渡す。ここから任意の判定を記述できる。ただし、まだ観測していない下流配列の特徴を知ることはできない。接合・モチーフの候補選択は、得られたprefixに基づく証拠とContinue方針を設計する必要がある。

現版はベースとなる実行系と例を完成させた初期版であり、特定の生物学的課題に対する選択精度を検証した完成済み分析法ではない。
