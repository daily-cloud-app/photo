# Daily Cloud Photo — Azure バックエンド

## ワンクリックデプロイ

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fdaily-cloud-app%2Fphoto%2Fmain%2Fazure%2Fazuredeploy.json)

> **注意**: 上記ボタンはテンプレートが公開リポジトリにホストされている場合に使用できます。
> それ以外の場合は `azuredeploy.json` をダウンロードし、Azure Portal または CLI で手動デプロイしてください。

---

## 前提条件

- Azure サブスクリプション（[無料アカウント](https://azure.microsoft.com/free/)）
- Azure CLI (`az` コマンド) がインストール済み — [インストールガイド](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)
- （オプション）Azure Functions Core Tools — [インストールガイド](https://docs.microsoft.com/en-us/azure/azure-functions/functions-run-local)
- Python 3.11+（ローカル開発用）

---

## クイックデプロイ

### オプション A: Azure Portal（ワンクリック）

1. 上記の **Deploy to Azure** ボタンをクリック
2. パラメータを入力（デフォルトのままでOK）
3. **確認および作成** → **作成** をクリック
4. デプロイ完了後（約3〜5分）、**出力** タブ → `apiEndpoint` をコピー
5. アプリ内: ドロワー → 設定 → エンドポイント URL を貼り付け → 保存

### オプション B: Azure CLI

```bash
# Azure にログイン
az login

# デプロイスクリプトを実行
chmod +x deploy.sh
./deploy.sh [RESOURCE_GROUP] [LOCATION] [APP_NAME]

# 例:
./deploy.sh daily-cloud-photo-rg eastus dailycloudphoto
```

### オプション C: 手動 CLI

```bash
# リソースグループの作成
az group create --name daily-cloud-photo-rg --location eastus

# ARM テンプレートのデプロイ
az deployment group create \
  --resource-group daily-cloud-photo-rg \
  --template-file azuredeploy.json \
  --parameters appName=dailycloudphoto

# 出力から Function App 名を取得
FUNC_APP=$(az deployment group show \
  --resource-group daily-cloud-photo-rg \
  --name azuredeploy \
  --query "properties.outputs.functionAppName.value" -o tsv)

# 関数コードのデプロイ
cd function_app
func azure functionapp publish $FUNC_APP --python
```

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

1. ドロワー → **設定** → API エンドポイント URL を入力 → **保存**
2. **接続テスト** で確認
3. ドロワー → **ログイン** からアカウント作成

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

## ローカル開発

```bash
cd function_app

# 仮想環境の作成
python -m venv .venv
source .venv/bin/activate  # Linux/Mac
# .venv\Scripts\activate   # Windows

# 依存パッケージのインストール
pip install -r requirements.txt

# local.settings.json の作成
cat > local.settings.json << 'EOF'
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "python",
    "COSMOS_CONNECTION": "<your-cosmos-connection-string>",
    "COSMOS_DATABASE": "dailycloudphoto",
    "STORAGE_CONNECTION": "<your-storage-connection-string>",
    "STORAGE_CONTAINER": "photos",
    "JWT_SECRET": "dev-secret-change-me",
    "REQUIRE_EMAIL": "true",
    "ENABLE_SHARE_URL": "true",
    "ENABLE_LABEL_SHARING": "true"
  }
}
EOF

# ローカルで実行
func start
```

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

## トラブルシューティング

### Function App が 404 を返す
- `host.json` のルートプレフィックスが `v1` であることを確認
- デプロイが完了しているか確認: `az functionapp show --name <app> --resource-group <rg>`

### Cosmos DB への接続タイムアウト
- `COSMOS_CONNECTION` アプリ設定が正しいことを確認
- Cosmos DB アカウントが同じリージョンにあるか確認

### アップロード失敗（SAS トークンエラー）
- ストレージアカウントに CORS が設定されているか確認
- `STORAGE_CONNECTION` のアカウントキーが正しいか確認
- `photos` コンテナが存在するか確認

### ログの確認
```bash
# ライブログのストリーミング
az functionapp log tail --name <function-app-name> --resource-group <rg>

# Application Insights の確認
az monitor app-insights query --app <insights-name> --analytics-query "traces | order by timestamp desc | take 50"
```
