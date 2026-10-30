# adaptive-cr 0.3.0

MinKNOWのRead Untilを使う、Crystal製のプログラム可能なadaptive samplingツールです。Dorado Basecall Serverで累積信号をbasecallし、minimap2で並列マッピングし、Crystalの任意の判定コードで **Continue / Accept / Reject** を返します。BEDは不要です。プロジェクト名は暫定名です。Moleflow本体とは独立しています。

通信・信号管理・並列実行・マッピング・判定・操作・監査ログはCrystalです。Doradoとの接続は、公式Pythonクライアントを使う常駐アダプターを正式な方式として採用します。ワーカーごとに一度起動し、ADC信号をバイナリで渡します。DoradoのCLI `dorado basecaller` とは別製品の **Dorado Basecall Server** を利用します。

Linux x86_64 / Crystal 1.22.0でビルド・テスト済み。公式クライアント7.13.6の入力構築を検証し、Moleflowと本物のgRPC・minimap2による結合試験を実施しました。**GPU付きDorado実サーバーと実機MinKNOWによる検証は未実施です。** 付属テストのbasecallerは固定配列を返す明示的なfixtureであり、精度やGPU処理能力の証明には使えません。

## ビルド

Crystal 1.22.0以上、Python 3.11以上（検証は3.12）と、Cコンパイラ・make・pkg-config・libnghttp2・OpenSSL・zlib・libyamlの開発パッケージ、POD5用のC++20コンパイラ・curl・tar・unzip・patchを用意します。Debian/Ubuntuでの依存ライブラリ導入とmiseを使った環境構築の例:

```sh
sudo apt-get install build-essential pkg-config libnghttp2-dev libssl-dev zlib1g-dev libyaml-dev curl unzip patch
mise install
mise exec -- shards install
mise exec -- python -m venv .venv
. .venv/bin/activate
python3 -m pip install -r requirements.txt
mise exec -- scripts/build.sh
mise exec -- scripts/test.sh
```

依存ライブラリはShardsで外部から取得します。`shard.lock`は検証したコミットを固定し、最新版に更新する場合は `mise exec -- shards update` を実行します。minimap2はShardsのインストール時にネイティブソースを取得・ビルドします。POD5ネイティブライブラリは `scripts/build.sh` が未導入時に取得・構築します。初回のセットアップにはネット接続が必要です。Pythonパッケージ・Doradoサーバー・GPUドライバは同梱していません。

## まずオフラインで動かす

プロジェクトのルートで実行します。設定内の相対パスも現在の作業ディレクトリ基準です。

```sh
bin/adaptive --validate
bin/adaptive --replay=examples/replay.jsonl
```

例の参照は独立に生成した人工配列 `host` と `virus` です。結果は `Reject`, `Accept`, `Reject`。最後のRejectはvirusの採用数上限1に達したためです。実際の研究用参照ではありません。

## POD5から実信号の診断入力を作る（0.3.0）

```sh
sh scripts/pod5.sh real.pod5 diagnostic --samples=20000
bin/adaptive -c run.json --check-signal=diagnostic/prefix.i16 --signal-metadata=diagnostic/prefix.json
```

`--read-id=UUID` で対象を指定できます。省略時は100 samples以上の最初のreadです。
指定したprefix長と実際の長さの小さい方を出力します。ADCを再校正せず、元のoffset、
scale、sample rate、start sampleを保持します。`read.json`にはUUID・channel・長さを
記録します。既存ディレクトリは上書きせず、失敗時は新規作成した出力を削除します。

この抽出はpod5.crを使うCrystal処理です。Doradoとの接続には引き続きPythonが必要です。
`--replay` は従来通り配列JSONLによるpolicy再生であり、POD5のライブ再生ではありません。
Moleflowで信号を配信する場合は、Moleflowの `scripts/pod5.sh prepare` を使ってください。

現在のpod5.cr APIではprefix抽出にも1 read全体の展開が必要です。このツールは展開前に
1,000万samplesを超えるreadを拒否します（ADC配列だけで最大約20 MB、RSS上限ではありません）。
出力prefixは100〜250,000 samplesです。巨大readの部分展開には未対応です。

## DoradoとMinKNOWにつなぐ

1. ONTのDorado Basecall Serverを導入し、付属READMEに従ってサーバーと対象化学条件のモデルを起動します。接続先、モデル設定名、クライアントとの互換性は実際のサーバー環境に合わせてください。
2. 下の例を `run.json` に保存し、参照、MinKNOWの **position serviceのポート**、CA証明書、モデル設定名を実環境に変更します。Managerの9501をそのままpositionポートとして使わないでください。
3. サーバー接続と実信号basecallの確認、観測モードを経て、排出を行う際に `observe` を `false` にします。詳しい導入・検証・停止・障害対応は [運用手順](docs/operations.md) にあります。

```json
{
  "host": "127.0.0.1",
  "port": 10001,
  "tls": true,
  "ca_file": "/data/rpc-certs/minknow/ca.crt",
  "first_channel": 1,
  "last_channel": 512,
  "reference": "/absolute/path/reference.mmi",
  "dorado_address": "ipc:///tmp/.guppy/5555",
  "dorado_model": "dna_r10.4.1_e8.2_400bps_5khz_fast",
  "python": ".venv/bin/python",
  "workers": 4,
  "policy": "contig",
  "targets": ["target_contig"],
  "quota": 0,
  "observe": true,
  "log": "run-001.jsonl"
}
```

```sh
bin/adaptive -c run.json --validate
bin/adaptive -c run.json --check-backend
bin/adaptive -c run.json
```

`--check-backend`は公式クライアントの接続までを確認し、Python・NumPy・クライアントの実バージョンをJSONで返します。信号のbasecallや実機制御までを検証するコマンドではありません。実信号を使う `--check-signal` は下記を参照してください。ライブ入力はraw int16 ADCです。チャンネル別offset・range/digitisation・sample rateをMinKNOWから取得し、公式クライアントへ渡します。

```sh
bin/adaptive -c run.json --check-signal=/data/prefix.i16 --signal-metadata=/data/prefix.json
```

`prefix.i16` は実測信号のlittle-endian int16 ADC列（100〜250000 samples）、`prefix.json` はその信号の `offset`, `scale`, `sample_rate`, `start_sample` を持つJSONです。`scale = range / digitisation`。実際の値を使用してください。このコマンドはMinKNOWへ接続せず、Doradoから得た配列をJSONへ出力します。空配列しか返らなければ診断失敗です。

PythonクライアントのバージョンはDorado Basecall Serverと**完全一致**させます。付属の `requirements.txt` は7.13.6向けです。モデル名もflow cell・kit・sample rateに適合するものを選び、例の5 kHz設定を無条件に流用しないでください。

認証が必要な環境では `MINKNOW_AUTH_TOKEN` または `PROTOCOL_TOKEN` を環境変数に設定します。クライアント証明書を使う場合は `MINKNOW_API_CLIENT_CERTIFICATE_CHAIN` / `MINKNOW_API_CLIENT_KEY` にパスを設定します。ログや設定例にトークンを記録しません。ローカルトークンの自動探索は無効です。実機の認証方式と接続権限は環境ごとに確認が必要です。

ログは既存ファイルを上書きしません。実行ごとに新しいパスを指定してください。SIGINT/SIGTERMで停止できます。

## 任意の判定を書く

`Adaptive::Policy`を継承し、以下のメソッドを実装します。

```crystal
class MyPolicy < Adaptive::Policy
  def decide(read : Adaptive::Evidence,
             experiment : Adaptive::Experiment,
             memory : Hash(String, String)) : Adaptive::Decision
    # read.sequences: Doradoのsplitを維持した配列一覧
    # read.hits: split番号とminimap2の座標・strand・MAPQ・CIGARなど
    # read.samples / channel / read_id
    # experiment.confirmed / reserved: グループ別採用操作数
    # memory: このリード世代だけの状態
    Adaptive::Decision.new(Adaptive::Choice::Continue, "more_signal_needed")
  end
end
```

`examples/custom.cr`が独自実行ファイルの入口、`examples/junction_policy.cr`が接合候補を採用する実装例です。

```sh
crystal build examples/custom.cr --release -o bin/adaptive-junction
bin/adaptive-junction -c run.json --replay=examples/replay.jsonl
```

この例は同じsplit内でhost/virusへのMAPQ・アラインメント長・クエリ座標の隣接を調べ、接合候補を100本まで採用します。構造変異の確定判定器ではありません。向き、反復配列、既知ブレークポイントなどは目的に応じて判定へ追加します。独自バイナリでは `policy` を `custom` にするとログでも区別できます。通常バイナリに `custom` を指定すると起動エラーになります。

判定は一つのcoordinator上で実行し、採用枠の予約と一体化しています。共有状態の競合を避けるため、ここでは重い計算やネットワーク待機を行わないでください。重い特徴量抽出は `src/adaptive/pool.cr` の並列ワーカー側へ追加し、Evidenceを拡張します。任意コードは信頼されたコンパイル時プラグインであり、サンドボックス化や実行時間の強制制限はありません。

## 標準判定と設定

| 設定 | 既定値 / 動作 |
| --- | --- |
| `policy` | `contig`。他に `motif`, `all`。`custom`は独自バイナリ専用 |
| `targets` | contig名の配列。いずれかへのMAPQ閾値以上のhitで採用 |
| `mapq` / `min_bases` | 20 / 300。短配列・contig判定で高信頼hitがない場合はContinue |
| `motif` | A/C/G/T文字列。順方向・逆相補鎖を検索。split間は連結しない |
| `quota` | 0は無制限。正数は対象contigまたはmotifグループ別の採用操作数上限 |
| `background_fraction` / `seed` | 0.0 / 42。非対象を再現可能なread-IDハッシュで一部採用 |
| `min_samples` / `step_samples` / `max_samples` | 2500 / 2000 / 20000。累積prefixを再basecallする |
| `deadline_ms` | 2000。アプリが最初のchunkを受信してからの判定期限 |
| `bridge_timeout_ms` | 3000。bridgeのI/O待機上限とサーバー結果待機の設定 |
| `bridge_startup_timeout_ms` | 60000。Python起動・接続・モデル初回読み込みの待機上限。リードの判定期限とは別 |
| `ack_timeout_ms` | 3000。操作応答待ち上限。超過で実行を停止し、操作を再送しない |
| `max_buffer_bytes` | 268435456。保存prefixと実行待ち/実行中signalコピーの合計量制限 |
| `workers` | 4。Crystalのparallel execution contextのスレッド数。各ワーカーに常駐Pythonクライアント1個 |
| `observe` | true。判定を記録するが、MinKNOWへ採用/排出操作を送らない |

motif判定は「現在までに読めたprefix内にmotifがあるか」を判定します。閾値以上のprefixで不在ならRejectになるため、分子後半のmotifを保証して探索する戦略ではありません。目的に応じてContinue条件を変更してください。

Acceptは `stop_further_data` で当該リードの信号配信を止め、分子の測定は続けます。Rejectは0.1秒の `unblock`。Continueは次の信号を待ちます。quotaのconfirmedは **操作成功の確認数** であり、完全長リード取得数やcoverageではありません。観測モードとreplayでは仮想的に採用数を増やします。

## 障害時と実装上の範囲

- 信号欠落・重複、容量不足、判定期限、basecaller障害、判断不能のサンプル上限では分子を残します。期限超過結果や前のリード世代の結果から排出しません。
- 複数チャネルが同時にquotaを満たしても、操作送信前に枠を予約します。失敗応答では枠を戻し、応答不明の操作は成功扱いしません。終了時に未確認操作数も記録します。
- 接続切断・不正な信号形式・監査ログ障害・操作応答タイムアウトでは実行を停止します。再接続後に古い状態を持ち越す自動復帰は実装していません。
- 正常停止・異常終了とも `end` イベントへ終了理由と未確認操作を記録します。ログ自体の障害では記録できない場合があり、stderrと終了コードも確認します。終了時は待機jobを破棄し、実行中処理を回収します。PythonはEOFで切断し、250 msで終了しなければ強制終了します。
- minimap2は `map-ont`、CIGARあり。参照indexを共有し、呼び出しごとに独立したthread bufferを使います。multipart indexはMAPQの扱いが不適切になるため拒否します。大きな参照では十分な `-I` で単一partのindexを事前作成してください。
- 期限はハードリアルタイム保証ではありません。初回chunk以前の装置側遅延、OSスケジューラ遅延、既に実行中のminimap2 C関数の強制中断は対象外です。期限超過後の結果は適用しません。
- メモリ設定はアプリ内signal量の上限です。gRPCバッファ、minimap2 index/作業領域、Python、GC、独自policyの状態を含むRSS上限ではありません。
- リードごとの機械学習スコア、オンラインcoverage、外部DB連動はpolicy/workerの拡張として実装できますが、この版に学習済みモデルや完全長coverage集計は含みません。変更塩基・品質スコアは現在のEvidenceへ渡していません。

## 検証

```sh
scripts/test.sh
# Moleflowを別途ビルドしてある場合。実gRPC・minimap2、fixture basecallerでの結合試験:
scripts/test.sh /absolute/path/moleflow/bin/moleflow
```

`docs/validation-v0.3.0.md`、`docs/integration-v0.3.0.jsonl`に今回の実行結果、`docs/research.md`に調査根拠、`docs/bugs.md`に修正事項を記録しています。長時間の負荷・GPU性能・実データでの選択精度は未測定です。

`scripts/package.sh` でアプリケーションのソースと実行ファイルをまとめられます。外部ライブラリは含まれず、展開後に `shards install` が必要です。出力先は既定で `dist/`、環境変数 `ADAPTIVE_DIST_DIR` で変更できます。配布物は実機検証前の研究用リリースです。
