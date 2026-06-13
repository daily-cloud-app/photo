# Daily Cloud Photo — Azure バックエンド

## ワンクリックデプロイ

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fdaily-cloud-app%2Fphoto%2Fmain%2Fazure%2Fazuredeploy.json)

---

## クイックデプロイ

1. 上記の **Deploy to Azure** ボタンをクリック
2. パラメータを入力（デフォルトのままでOK） → **確認および作成** → **作成**
3. デプロイ完了後（約3〜5分）、**出力** タブ → `functionAppName` をコピー
4. 関数コードをデプロイ:
   ```bash
   cd function_app
   func azure functionapp publish <functionAppName> --python
   ```
5. 出力タブから `apiEndpoint` をコピー
6. アプリ内: ドロワー → 設定 → エンドポイント URL を貼り付け → 保存

---

## パラメータ一覧

| パラメータ | デフォルト | 説明 |
|-----------|-----------|------|
| `appName` | `dailycloudphoto` | 全リソースのベース名 |
| `location` | リソースグループのリージョン | Azure リージョン |
| `jwtSecret` | 自動生成 | JWT 署名用のシークレットキー |
| `accessTokenExpireMinutes` | `60` | アクセストークンの有効期限（分） |
| `refreshTokenExpireDays` | `30` | リフレッシュトークンの有効期限（日） |
| `requireEmail` | `true` | サインアップ時にメール必須 |
| `requirePhone` | `false` | サインアップ時に電話番号必須 |
| `enableShareUrl` | `true` | アップロードURL共有機能 |
| `enableLabelSharing` | `true` | ラベル共有機能 |

---

## アプリでの接続

7. **接続テスト** で確認
8. ドロワー → **ログイン** からアカウント作成

---

## アーキテクチャ

```
                          ┌─────────────────────────────────────────┐
                          │         Azure Function App              │
ユーザー ── HTTPS ────────▶  (Python 3.11, v2 Programming Model)   │
                          │                                         │
                          │  ┌─────────┐  ┌──────────┐  ┌───────┐ │
                          │  │ Auth    │  │ Photos   │  │ Share │ │
                          │  │ (JWT)   │  │ CRUD     │  │ APIs  │ │
                          │  └────┬────┘  └────┬─────┘  └───┬───┘ │
                          └───────┼────────────┼─────────────┼─────┘
                                  │            │             │
                    ┌─────────────┼────────────┼─────────────┼─────┐
                    │             ▼            ▼             ▼     │
                    │  ┌──────────────┐  ┌──────────────────────┐  │
                    │  │  Cosmos DB   │  │  Azure Blob Storage  │  │
                    │  │  (Serverless)│  │  (Photos + Thumbs)   │  │
                    │  │              │  │                      │  │
                    │  │  • users     │  │  • users/{uid}/...   │  │
                    │  │  • photos    │  │  • thumbnails/...    │  │
                    │  └──────────────┘  └───────────┬──────────┘  │
                    │                                │              │
                    │                    ┌───────────▼──────────┐   │
                    │                    │  Blob Trigger        │   │
                    │                    │  (EXIF + Thumbnail)  │   │
                    │                    └──────────────────────┘   │
                    └──────────────────────────────────────────────┘
```

### コンポーネント

| コンポーネント | Azure サービス | 対応サービス (AWS/GCP) |
|---------------|--------------|---------------------|
| API & ロジック | Azure Functions (Python) | Lambda / Cloud Functions |
| データベース | Cosmos DB (NoSQL, Serverless) | DynamoDB / Firestore |
| ファイルストレージ | Azure Blob Storage | S3 / Cloud Storage |
| 認証 | カスタム JWT (PyJWT + bcrypt) | Cognito / Firebase Auth |
| モニタリング | Application Insights | CloudWatch / Cloud Logging |
| IaC | ARM Template | CloudFormation / — |

### 認証設計

この実装は**自己完結型 JWT 認証**を使用しています（外部認証プロバイダー不要）:
- ユーザーは Cosmos DB に bcrypt ハッシュ化パスワードで保存
- アクセストークン: 短期間の JWT（デフォルト60分）
- リフレッシュトークン: 長期間の JWT（デフォルト30日）
- 外部依存なし（Azure AD B2C、Firebase 等不要）
- パスワードリセットはサーバー生成コード経由（セルフホスト環境ではログ出力）

---

## リソースの削除

```bash
# リソースグループ内の全リソースを削除
az group delete --name daily-cloud-photo-rg --yes --no-wait
```

> これにより全データ（写真、ユーザー、メタデータ）が完全に削除されます。

---

## コスト目安

全サービスが**サーバーレス/従量課金**です。使用量が少なければ非常に安価です。

上記はあくまで目安です。実際の費用は利用状況により異なります。各クラウドプロバイダーの請求ダッシュボードを定期的に確認してください。

| サービス | 料金モデル | 無料枠/目安 |
|---------|-----------|------------|
| Azure Functions | 従量課金プラン | 月100万実行まで無料 |
| Cosmos DB | サーバーレス (RU単位) | 最初の 1000 RU/s 無料枠あり |
| Blob Storage | GB単位課金 | 約 $0.02/GB/月 (Hot tier) |
| Application Insights | GB単位取り込み | 月5 GB まで無料 |

**個人利用（写真1,000枚未満）の月額目安:** $1〜5/月

---

## 本番運用時のセキュリティ推奨事項

テンプレートには基本的なセキュリティ（HTTPS のみ、Blob のパブリックアクセス無効、TLS 1.2）が含まれています。本番運用する場合は以下も検討してください:

- **JWT シークレットのローテーション**: JWT_SECRET アプリ設定を定期的にローテーション
- **ネットワーク制限**: Cosmos DB に Azure Private Endpoints を使用
- **WAF**: Function App の前に Azure Front Door + WAF を配置
- **CORS の制限**: 許可するオリジンをアプリのドメインに限定
- **レート制限**: Azure API Management またはカスタムミドルウェアで設定
- **Key Vault**: シークレットをアプリ設定ではなく Azure Key Vault に保存
- **マネージド ID**: Cosmos DB アクセスにシステム割り当てマネージド ID を使用
- **バックアップ**: Cosmos DB の継続的バックアップを有効化

---

## API リファレンス

完全な API 仕様は [API.md](../aws/API.md) を参照してください。
この Azure バックエンドでは仕様の全エンドポイントが実装されています。
