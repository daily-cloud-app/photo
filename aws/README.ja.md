# Daily Cloud Photo — AWS バックエンド

> AWS アカウントが必要です（[無料で作成](https://aws.amazon.com/free/)）

## ワンクリックデプロイ

`LambdaCodeBucket` を空欄にすると、GitHub Releases から自動的にコードをダウンロードしてデプロイします。

[![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](https://console.aws.amazon.com/cloudformation/home#/stacks/new?stackName=daily-cloud-photo&templateURL=https://raw.githubusercontent.com/daily-cloud-app/photo/main/aws/template.yaml)

### クイックスタート

1. AWS コンソール → **CloudFormation** → **スタックの作成**
2. `template.yaml` をアップロード
3. パラメータ:
   - `LambdaCodeBucket`: **空欄のまま**（GitHub から自動ダウンロード）
   - その他はデフォルトでOK
4. 「IAM リソースが作成される場合があることを承認」にチェック
5. **作成** をクリック
6. 完了後、**出力** タブの `ApiEndpoint` をアプリに入力

---

## パラメータ一覧

| パラメータ | デフォルト | 説明 |
|-----------|-----------|------|
| AppName | `daily-cloud-photo` | リソース名のプレフィックス |
| RequireEmail | `true` | サインアップ時にメール必須 |
| RequirePhone | `false` | サインアップ時に電話番号必須 |
| PhotosBucketName | (自動生成) | 写真用 S3 バケット名 |
| LambdaCodeBucket | (空欄) | 空欄=GitHub自動DL / 指定=手動アップロード |
| LambdaCodeKey | `daily-cloud-photo/lambda.zip` | Lambda ZIP の S3 キー |
| GitHubReleaseUrl | (最新リリース) | Lambda ZIP のダウンロード元URL |
| EnableShareUrl | `true` | アップロードURL共有機能 |
| EnableLabelSharing | `true` | ラベル共有機能 |

## アプリでの接続

1. ドロワー → **設定** → エンドポイント URL を入力 → **保存**
2. **接続テスト** で確認
3. ドロワー → **ログイン** からアカウント作成

## スタックの削除

1. **S3 バケット**（写真用）を空にする（バージョニング含む）
2. **CloudFormation** → スタック → **削除**

## アーキテクチャ

```
ユーザー → API Gateway (HTTP API) → Lambda (統合ハンドラー)
                                        ├── Cognito (認証)
                                        ├── S3 (写真保存 + サムネイル)
                                        ├── DynamoDB (メタデータ)
                                        └── S3 Trigger Lambda (EXIF抽出 + サムネイル生成)
```

- 全 API を1つの Lambda で処理（パスベースルーティング）
- ユーザーの写真は `users/{cognito_sub}/` プレフィックスで分離
- presigned URL で S3 に直接アップロード（Lambda を経由しない）
- S3 トリガーで自動的に EXIF 解析 + サムネイル生成 + DynamoDB 登録

## コスト目安

すべて従量課金。少人数であれば AWS 無料枠内に収まります。

上記はあくまで目安です。実際の費用は利用状況により異なります。各クラウドプロバイダーの請求ダッシュボードを定期的に確認してください。

| サービス | 無料枠 |
|----------|--------|
| Lambda | 月100万リクエスト |
| API Gateway | 月100万リクエスト |
| DynamoDB | 25GB + 25WCU/25RCU |
| S3 | 5GB（12ヶ月間） |
| Cognito | 月50,000 MAU |

## 本番運用時のセキュリティ推奨事項

テンプレートには基本的なセキュリティ（S3パブリックアクセスブロック、トークン有効期限チェック）が含まれています。本番運用する場合は以下も検討してください:

- **API Gatewayスロットリング**: ステージ設定でレート制限を追加（総当り攻撃対策）
- **WAF**: API Gatewayの前にWAFを配置（悪意あるリクエストのブロック）
- **CORSの制限**: `AllowOrigins` を特定ドメインに限定
- **CloudTrail**: API呼び出しの監査ログ有効化
- **IAMロール最小権限化**: 不要なアクション（`Scan` 等）の除去
- **共有URLの制限**: ファイルサイズ制限、アップロード回数制限、Content-Type 検証の追加を検討
