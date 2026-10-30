# 0.3.0の更新

- grpc/proto/minknowを公開版Moleflowと同じ固定リビジョンへ更新。
- 新版でも必要なMinKNOWのsetupコンストラクター修正と、明示的な
  auto_local_auth: falseの尊重を再適用。既存の回帰テストを維持。
- 生成済みprotobufの更新に伴い、アプリ側Float#to_bits補助を削除。
- 修正版pod5.crを同梱。POD5からADC prefixと校正値を抽出する専用CLIを追加。
- 既存出力の保護、エラー時の片付け、read ID指定、prefix長、校正値を検証。
- Dorado通信のPythonアダプターとライブ判定の安全動作は維持。

以下は過去の修正記録です。

# 今回の修正と回帰テスト

## 0.2.0で修正した問題

- **遅い独自policyから期限後にRejectを送れる。** worker完了時の期限確認に加え、policyから戻った後も期限を確認する。遅いRejectをAcceptへ切り替える回帰テストを追加。既にCコードで実行中の処理やpolicyそのものを強制中断する仕組みではない。
- **異常終了時に終了ログが欠落する。** `end` をensureへ移し、`outcome`、未確認操作、予約数を保存。起動失敗・サーバー切断を検証。
- **少量の監査ログがバッファに残り、実行中に観測できない。** ロガー側で各行をflushする。fsyncによる電源断耐性を保証するものではない。SIGTERM・切断試験は実行中のdecision行を検出してから障害を注入する。
- **対象contig名の誤記を検出しない。** 実際にロードしたminimap2 indexを使い、validate・replay・live開始時に対象名を検証する。
- **接続初期化とリード処理に同じ短いタイムアウトを使う。** 初回モデル読み込み用の `bridge_startup_timeout_ms` を分離。
- **キュー満杯のFalseを曖昧な応答と扱い、不必要に待つ。** ピン留めした公式Python実装に合わせて即時エラー扱いとし、分子を温存する。
- **Dorado出力を `str()` に無条件変換する。** bytesはASCIIとしてdecodeし、非文字列・不正DNA文字列を拒否する。DAQ値のNaN・無限大・非正scale、壊れた入力も検出する。
- **停止後も待機jobを処理し、結果送信が停止を妨げ得る。** 待機jobを破棄、結果Channelを閉じ、実行中workerを回収する。Pythonの正常切断に猶予を設け、ハング時は終了させる。
- **期限切れjobにもbasecall・mappingを始める。** 待機中に期限を超えたjobと、basecall終了時に期限を超えたjobは、それ以降の高価な処理を省く。
- **CLIに排他的なモードを同時指定すると片方が黙って無視される。** 明示的なエラーにする。

接続確認だけでは実際のbasecall経路を試せなかったため、実信号と校正値を入力する `--check-signal` も追加した。これ自体を実サーバーとの検証完了とみなさない。

## 依存先で見つかった問題

1. **minknowのStreamSetup初期化が生成コードと不整合。** convenience helperはキーワード引数付き `.new(...)` を呼んでいたが、同梱生成型にはそのinitializerがない。`.new`後のsetterへ変更。raw type、channel range、chunk sizeをencode/decodeする回帰テストを追加。
2. **minknowで明示的な `auto_local_auth: false` が無視される。** `if value = auto_local_auth` はfalseを未指定と同じ分岐へ落とし、localhostで不要なTLS認証探索を実行した。nilかどうかを判定するよう修正。false指定時のmetadata取得を回帰テスト化。Moleflowとのplain/TLS接続も検証。
3. **minimap2-crのmultipart MAPQを適切に利用できない。** partごとの結果の連結のみでは競合hitに対する全体のMAPQとならない。bindingを全面改変せず、本アプリでmultipartを明示拒否。これは一般的なminimap2本体のバグという意味ではない。

最初の2件は当初ローカルパッチで対応し、その後minknow上流のコミット `e925e92487ca3627baa912a2c792abc207b4542e` に取り込まれた。Moleflowで既に修正していたgRPCのstreaming/FFI patchも当時の配布物には適用済みで同梱した。今回新たにgRPCの同じ問題を発見したと数え直していない。

## この実装の検証中に修正した点

- readを終える内部メソッドに `finalize` を使うとCrystalのGC finalizerと衝突するため `finish_read` に変更。
- CrystalのFile APIにない `wx` モードを使わず、LinuxのO_EXCLでログを新規作成。既存ログの非破壊をテスト。
- 遅延結果から排出しないよう、timerだけでなく結果適用直前も期限を確認。
- IO::Memoryの長さだけをclearして容量を保持するのを避け、終端readのバッファ自体を交換。
- quotaの同時到達は予約で防止。操作失敗では枠を戻す。重複ackは二重加算しない。
- split配列を連結して偽接合を作らない。接合例のテストは「同一配列内」と「別split」を区別。
- 終了直前の操作がackされない場合を成功とみなさず、`unacknowledged_actions`を終了ログへ追加。
- 標準実行ファイルが `policy: custom` を黙って通常判定に落とさず、起動エラーにする。
- 設定の未知のキーを拒否し、指定ミスを放置しない。

これらの内部問題は開発中に修正したもので、以前配布したMoleflowの欠陥を意味しない。
