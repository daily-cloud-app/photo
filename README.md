# Daily Cloud Photo — Infrastructure Samples

- [English](#english)
- [日本語](#日本語)

---

## English

Sample backend implementations for the Daily Cloud Photo app. 
These are reference implementations to help you get started — feel free to modify or use them as a base for your own setup.

All implementations have been verified with the app for basic operations (signup, upload, cloud sync, label sharing, storage trigger).

*Disclaimer: These are reference samples, not production-ready code. They work but are kept simple. Review, harden, and adapt them to your own security, compliance, scaling, and cost requirements before real use. Provided "as is" without warranty; use at your own risk. Cloud usage may incur charges — monitor billing and clean up unused resources.*

### Providers

These implementations are provided as samples.
You are not limited to these providers — any server that implements the [API specification](API.md) will work with the app.

- [**AWS**](aws/README.md)
- [**GCP**](gcp/README.md)
- [**Azure**](azure/README.md)

### Service Comparison

| Component | AWS | GCP | Azure |
|-----------|-----|-----|-------|
| API | API Gateway | Cloud Run | Functions HTTP Trigger |
| Logic | Lambda | Cloud Functions | Azure Functions |
| Database | DynamoDB | Firestore | Cosmos DB |
| File Storage | S3 | Cloud Storage | Blob Storage |
| Auth | Cognito | Firebase Auth | Custom JWT |
| IaC | CloudFormation | Terraform | ARM Template |
| Thumbnail Trigger | S3 Event | Eventarc | Blob Trigger |

---

## 日本語

Daily Cloud Photo アプリ用のバックエンド実装サンプルです。
これらはリファレンス実装であり、自由に変更して利用できます。

すべての実装はアプリとの基本操作（サインアップ、アップロード、クラウド同期、ラベル共有、ストレージトリガー）で動作確認済みです。

*免責事項: これらはリファレンス用のサンプルであり、本番運用向けのコードではありません。動作はしますがシンプルな構成です。実利用の前に、セキュリティ・コンプライアンス・スケーリング・コストなどをご自身の要件に合わせて確認・強化・調整してください。現状のまま（"as is"）無保証で提供され、利用は自己責任です。クラウド利用で課金が発生する場合があるため、請求の監視と不要リソースの削除をお願いします。*

### プロバイダー

これらの実装はサンプルとして提供されています。
[API 仕様](API.md) に準拠するサーバーであれば、これらのプロバイダーに限りません。

- [**AWS**](aws/README.md)
- [**GCP**](gcp/README.md)
- [**Azure**](azure/README.md)

### サービス比較

| コンポーネント | AWS | GCP | Azure |
|---------------|-----|-----|-------|
| API | API Gateway | Cloud Run | Functions HTTP Trigger |
| ロジック | Lambda | Cloud Functions | Azure Functions |
| データベース | DynamoDB | Firestore | Cosmos DB |
| ファイルストレージ | S3 | Cloud Storage | Blob Storage |
| 認証 | Cognito | Firebase Auth | Custom JWT |
| IaC | CloudFormation | Terraform | ARM Template |
| サムネイルトリガー | S3 Event | Eventarc | Blob Trigger |
