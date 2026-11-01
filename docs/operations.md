# 運用手順（0.3.0）

この版は実行系、独自policyの入口、異常時の処理、診断、再現可能な試験をまとめた研究用リリースです。GPU Dorado実サーバー・実機MinKNOW・生物学的な選択精度の検証は、利用環境で行います。

## 1. 環境を固定する

READMEのビルド依存を導入し、プロジェクトルートで実行します。

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
scripts/build.sh
PATH="$PWD/.venv/bin:$PATH" scripts/test.sh
```

ライブ用のPythonには公式wheelのある版を使います。固定している `ont-pybasecall-client-lib==7.13.6` の [配布物](https://pypi.org/project/ont-pybasecall-client-lib/7.13.6/#files) はCPython 3.13までで、`requirements.txt` 全体では3.11〜3.13が対象です。`mise.toml` とCIは最新Pythonを使うため、ライブ用には対応するPythonで別途 `.venv` を作成します。標準ライブラリだけでオフラインreplayとfixture試験を実行でき、公式クライアント未導入なら専用の2試験は理由付きでskipします。導入後は同じ `scripts/test.sh` で追加実行されます。

クライアント版はDorado Basecall Serverと一致させます。サーバーは別途導入し、その `--version` を確認してください。異なるサーバー版を使う場合はrequirementsも一致させ、その組み合わせで再検証します。Dorado CLI本体の版と混同しないでください。サーバー・GPU・実機を使用した検証は引き続き未実施です。

GPU・モデル・参照indexは実際のrunに必要なものを事前に用意します。モデル名の例は5 kHz条件用で、使用するflow cell・kit・sample rateとの適合性を自動判定する機能はありません。

## 2. 設定と参照を確認する

READMEの `run.json` 例を編集します。必須は `reference`、contig policyなら `targets` です。ライブではMinKNOW positionのポート、TLS・認証、チャネル範囲、Dorado接続先とモデルも確認します。`python` は `.venv/bin/python`、`observe` は最初trueにします。相対パスの基準は設定ファイルの場所ではなく**現在の作業ディレクトリ**です。

```sh
bin/adaptive -c run.json --validate
bin/adaptive -c run.json --check-backend
```

validateは設定キー、参照index、対象contigを確認します。check-backendは本物の公式clientで接続し、実バージョン情報をJSONへ出します。標準設定ではfixtureを受け入れません。`allow_test_bridge` と `fixture_sequence` は試験専用です。

## 3. 実信号でbasecallする

測定データから取り出したprefixを `prefix.i16` として用意します。形式はヘッダーなしlittle-endian signed int16 ADC。pAへ変換済みのfloat列ではありません。100〜250000 samplesに制限していますが、正常なbasecallが期待できる実際のprefix長を使います。

同じ信号に対応する `prefix.json` を用意します。以下の数値は形式説明用であり、信号に合った値へ必ず置き換えます。

```json
{"offset": -12.5, "scale": 0.14, "sample_rate": 5000.0, "start_sample": 1234}
```

scaleはチャンネルのrange/digitisation、start_sampleはrun開始からのsample indexです。

```sh
bin/adaptive -c run.json --check-signal=prefix.i16 --signal-metadata=prefix.json > basecall-check.json
```

成功時は実配列とsplitごとの結果が出ます。これはDoradoへの送受信を確認する診断であり、精度の保証ではありません。既知の配列・参照へ照合してください。実信号や配列は配布テストへ混ぜず、研究データとして管理します。

## 4. 観測から開始する

MinKNOWで適切なrunを開始し、`observe: true` で実行します。

```sh
bin/adaptive -c run.json
```

`start` でbackend、モデル、クライアント版、sample rate、参照を確認します。`evaluation` でworker_ms・policy_ms・配列長・hit数、`decision` でelapsed_ms・理由を確認します。Doradoが遅すぎると `decision_deadline` や `worker_error` が増えます。実際のチャネル数・参照・GPUで測定し、workersやprefix長を調整してください。512チャネルのfixture試験はGPU能力の測定ではありません。

観測で期待する判定を確認後、別のlogパスを指定し、`observe: false` にして実行します。Acceptは分子の測定を継続したまま信号配信を止め、Rejectは0.1秒unblockします。quotaは採用操作数の上限であり、coverageや得られた完全長分子数ではありません。

## 5. 停止・障害の確認

Ctrl-CまたはSIGTERMで停止します。正常終了コードは0、設定・接続・処理系の致命的エラーは1です。basecallerの個々のjob失敗では、その分子を残して継続するため、終了コードだけでなくログも確認します。

| イベント・理由 | 意味と対応 |
| --- | --- |
| `decision_deadline` | 受信開始からの期限超過。分子を温存。prefix長・worker/GPU負荷・期限を見直す |
| `signal_gap_or_overlap` | 信号が連続していない。分子を温存。初回chunkとstreamを確認 |
| `signal_budget`, `sample_limit` | 保存量または判定に使う信号の上限。分子を温存 |
| `worker_error` | basecall/mapping障害。直前のerror内容、接続・モデル・キューを確認 |
| `stale_result` | 古い世代、終端read、期限後の結果。操作へ使わない |
| `ack` status=0 | MinKNOWが操作成功を返した。分子の完全長取得の証明ではない |
| `ack` status≠0 | 操作失敗。予約を解除し、自動で同じ操作を再送しない |
| `error` | 実行を停止する障害。stderrも確認 |
| `end` | outcomeは `stream_end`, `signal`, `error`。未確認操作数と予約数を確認 |

操作応答タイムアウト時は、既に適用された可能性を残して停止し、成功扱いや再送をしません。ログは新規作成専用で、同じパスで再実行すると失敗します。ディスク障害時には最終ログを書けないため、stderrも保存してください。終了直前の未確認操作は次回runへ持ち越しません。

Crystal policyは信頼されたコンパイル時コードです。coordinatorをブロックするpolicyは遅延を招きます。戻った時点で期限を越えていれば排出を抑止しますが、無限ループや実行中C関数を強制中断する保証はありません。

## 6. 配布・再現

`scripts/test.sh /absolute/path/moleflow/bin/moleflow` が結合試験を追加します。Moleflowは独立したプロジェクトです。試験データは人工配列、basecallerは明示的fixtureです。実gRPC・TLS・minimap2・操作応答・終了処理を確認します。

`scripts/package.sh` がソース、固定依存、ビルド済みバイナリ、文書、試験結果をtar.gzへまとめ、SHA-256も出力します。Pythonパッケージ、Dorado、モデル、GPUランタイム、実データは同梱しません。
