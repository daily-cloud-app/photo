# Daily Cloud Photo — Azure Backend

- [English](#english)
- [日本語](#日本語)

---

## English

> Requires an Azure account ([create free](https://azure.microsoft.com/free/))
> and a Microsoft Entra **External ID** tenant (native authentication).

Authentication is delegated to **Microsoft Entra External ID** using the
[native authentication API](https://learn.microsoft.com/entra/identity-platform/reference-native-authentication-api).
The backend never stores passwords, password hashes, reset codes or
verification codes, and never issues its own JWTs. Infrastructure is defined in
**Bicep** and runs on the **Flex Consumption** plan.

### Prerequisites: Entra External ID tenant

Creating an external tenant and its user flow is portal-driven and cannot be
fully scripted. Do this once before deploying:

1. In the [Microsoft Entra admin center](https://entra.microsoft.com), create an
   **external** tenant. Note its **subdomain** (e.g. `contoso` for
   `contoso.onmicrosoft.com`) and **tenant (directory) ID**.
2. Register an application (or let `deploy.sh` create it via Graph). On the app:
   - Enable **public client and native authentication flows**.
   - Grant admin consent.
3. Create an **Email + Password** user flow with **email one-time passcode**
   verification, and enable **self-service password reset (SSPR)**.
4. **Associate** the app registration with the user flow.

`deploy.sh` automates the app registration via Microsoft Graph. The user flow
creation and association remain manual (portal-only) at this time.

### Quick Start

[![Open in Cloud Shell](https://img.shields.io/badge/Azure-Cloud_Shell-blue?logo=microsoftazure)](https://shell.azure.com)

1. Click the **Cloud Shell** button above.
2. Clone, configure your external tenant, and deploy:
   ```bash
   [ -d photo ] || git clone https://github.com/daily-cloud-app/photo.git
   cd photo && git checkout -- . && git pull --ff-only && cd azure

   # Point the backend at your external tenant.
   export ENTRA_TENANT_SUBDOMAIN=<yourtenant>
   export ENTRA_TENANT_ID=<tenant-guid>
   # Optional: reuse an existing app registration instead of creating one.
   # export ENTRA_CLIENT_ID=<app-client-id>

   # Optional overrides (defaults shown):
   export RESOURCE_GROUP=daily-cloud-photo-rg
   export LOCATION=eastus          # must be a Flex Consumption region
   export APP_NAME=dailycloudphoto

   chmod +x deploy.sh && ./deploy.sh
   ```
3. Copy the API endpoint URL from the output into the app.

`deploy.sh` is a thin wrapper: **Bicep** provisions the infrastructure,
**Microsoft Graph** configures the app registration, and **OneDeploy** publishes
the code to the Flex Consumption deployment container (no legacy
`config-zip` content-share flow).

### Configuration

Deployment is configured through environment variables consumed by `deploy.sh`,
and Bicep parameters (`bicep/main.bicepparam`).

| Setting | Default | Description |
|---------|---------|-------------|
| `ENTRA_TENANT_SUBDOMAIN` | (required) | External tenant subdomain |
| `ENTRA_TENANT_ID` | (required) | External tenant (directory) GUID |
| `ENTRA_CLIENT_ID` | (auto-created) | App registration client ID; set to reuse |
| `RESOURCE_GROUP` | `daily-cloud-photo-rg` | Target resource group |
| `LOCATION` | `eastus` | Azure region (Flex Consumption) |
| `APP_NAME` | `dailycloudphoto` | Base name for all resources |
| `entraScopes` (Bicep) | `openid offline_access` | Token scopes |
| `requireEmail` (Bicep) | `true` | Require email for signup |
| `enableShareUrl` (Bicep) | `true` | Upload URL sharing feature |
| `enableShareDownloadUrl` (Bicep) | `true` | Download URL sharing feature |
| `enableLabelSharing` (Bicep) | `true` | Label sharing between users |
| `shareUploadUrlExpiryHours` (Bicep) | `24` | Upload URL validity (hours) |
| `shareDownloadUrlExpiryHours` (Bicep) | `72` | Download URL validity (hours) |
| `maximumInstanceCount` (Bicep) | `100` | Flex Consumption max instances |
| `instanceMemoryMB` (Bicep) | `2048` | Flex Consumption per-instance memory |
| `pythonVersion` (Bicep) | `3.11` | Python runtime version |

### Deployment flow

```
./deploy.sh
   ├─ Bicep deploy (bicep/main.bicep)
   │     ├─ Managed Identity + least-privilege RBAC
   │     ├─ Storage (photos + deployment container)
   │     ├─ Cosmos DB (users mapping + photos)
   │     └─ Flex Consumption Function App + App Insights
   ├─ Microsoft Graph
   │     └─ App registration (public client / native auth)
   ├─ OneDeploy (function code, remote build)
   └─ Event Grid subscription (thumbnail trigger) → API endpoint
```

### Connecting the App

1. **Settings** → Enter the endpoint URL → **Save**
2. Run **Connection Test**
3. **Login** → Create account (email + password) → enter the **email OTP**

### Deleting Resources

[![Open in Cloud Shell](https://img.shields.io/badge/Azure-Cloud_Shell-blue?logo=microsoftazure)](https://shell.azure.com)

```bash
az group delete --name daily-cloud-photo-rg --yes --no-wait
```

Users created in the external tenant are removed separately in the Entra admin
center (or via Microsoft Graph).

### Architecture

```
User → Azure Functions (HTTP, Flex Consumption) → route dispatch
          ├── Entra External ID (native auth): signup / OTP / signin / SSPR
          │        (backend relays credentials; Entra issues all tokens)
          ├── Token validation (Entra JWKS, RS256) on protected endpoints
          ├── Blob Storage (photo storage + thumbnails, SAS URLs)
          ├── Cosmos DB — users: username → email / Entra object id mapping
          │             — photos: metadata (partitioned by Entra user id)
          └── Blob (Event Grid) trigger → EXIF + thumbnail generation
```

- Authentication delegated entirely to Entra External ID (no bcrypt, no JWT
  secret, no reset/verification codes stored).
- The `users` container stores only a `username → email / entraObjectId`
  mapping so username login and label sharing keep working. Between the
  stateless `/auth/signup` and `/auth/confirm` calls, an opaque, short-lived
  `continuation_token` (a flow handle, not a credential) is stored transiently.
- Platform storage (host + deployment package) uses **managed identity**;
  photo data-plane access uses connection strings for SAS generation.
- User photos isolated under `users/{uid}/` where `uid` is the stable Entra id.

### API contract (unchanged for the app)

| Endpoint | Request | Response |
|----------|---------|----------|
| `POST /auth/signup` | `{username, password, email}` | `{confirmationRequired: true}` |
| `POST /auth/confirm` | `{username, confirmationCode}` | `{message}` |
| `POST /auth/signin` | `{username, password}` | `{accessToken, refreshToken, expiresIn}` |
| `POST /auth/refresh` | `{refreshToken}` | `{accessToken, refreshToken, expiresIn}` |
| `POST /auth/forgot-password` | `{username}` | `{message}` (never reveals existence) |
| `POST /auth/reset-password` | `{username, confirmationCode, newPassword}` | `{message}` |

### Cost Estimate

All services use serverless/consumption pricing. Low usage is extremely cheap.

These are estimates only. Actual costs depend on usage patterns and may vary.
Always monitor your cloud provider's billing dashboard.

| Service | Free Tier |
|---------|-----------|
| Azure Functions (Flex Consumption) | Monthly free grant of execution time |
| Cosmos DB (serverless) | Pay per request unit consumed |
| Blob Storage | ~$0.02/GB/month (Hot tier) |
| Application Insights | 5 GB/month |
| Entra External ID | Monthly active users free tier |

### Security Recommendations for Production

These are examples only — not an exhaustive list. Evaluate your own requirements
and apply additional measures as needed.

- **Managed Identity everywhere**: Extend MI-based access to Cosmos DB
  (data-plane RBAC) to remove connection strings.
- **Network restrictions**: Use Azure Private Endpoints for Cosmos DB and
  Storage ([docs](https://learn.microsoft.com/azure/cosmos-db/how-to-configure-private-endpoints)).
- **WAF**: Place Azure Front Door with WAF in front of the Function App
  ([docs](https://learn.microsoft.com/azure/web-application-firewall/overview)).
- **CORS restriction**: Limit allowed origins to specific domains.
- **Rate limiting**: Configure Azure API Management or custom middleware.
- **Conditional Access / MFA**: Enforce MFA for the external tenant users.
- **Share URL limits**: Consider file size limits, upload count limits, and
  Content-Type validation.

---

## 日本語

> Azure アカウント（[無料で作成](https://azure.microsoft.com/free/)）と、
> Microsoft Entra **External ID** テナント（ネイティブ認証）が必要です。

認証は **Microsoft Entra External ID** の
[ネイティブ認証 API](https://learn.microsoft.com/ja-jp/entra/identity-platform/reference-native-authentication-api)
に委譲します。バックエンドはパスワード・パスワードハッシュ・リセットコード・
確認コードを一切保存せず、独自 JWT も発行しません。インフラは **Bicep** で定義し、
**Flex Consumption** プランで動作します。

### 前提: Entra External ID テナント

外部テナントとユーザーフローの作成はポータル操作が必要で、完全な自動化はできません。
デプロイ前に一度だけ以下を行ってください。

1. [Microsoft Entra 管理センター](https://entra.microsoft.com) で **外部**テナントを作成。
   **サブドメイン**（例: `contoso.onmicrosoft.com` なら `contoso`）と
   **テナント（ディレクトリ）ID** を控える。
2. アプリを登録（`deploy.sh` が Graph 経由で作成可）。アプリで:
   - **パブリッククライアントとネイティブ認証フロー**を有効化。
   - 管理者の同意を付与。
3. **メール + パスワード**のユーザーフローを作成し、**メール OTP** 確認と
   **セルフサービスパスワードリセット（SSPR）**を有効化。
4. アプリ登録をユーザーフローに **関連付け**る。

`deploy.sh` はアプリ登録を Microsoft Graph で自動化します。ユーザーフローの作成と
関連付けは現状ポータル操作（手動）です。

### クイックスタート

[![Open in Cloud Shell](https://img.shields.io/badge/Azure-Cloud_Shell-blue?logo=microsoftazure)](https://shell.azure.com)

1. 上記の **Cloud Shell** ボタンをクリック。
2. クローンし、外部テナントを設定してデプロイ:
   ```bash
   [ -d photo ] || git clone https://github.com/daily-cloud-app/photo.git
   cd photo && git checkout -- . && git pull --ff-only && cd azure

   # バックエンドを外部テナントに向ける
   export ENTRA_TENANT_SUBDOMAIN=<yourtenant>
   export ENTRA_TENANT_ID=<tenant-guid>
   # 任意: 既存のアプリ登録を再利用する場合
   # export ENTRA_CLIENT_ID=<app-client-id>

   # 任意の上書き（デフォルト値）:
   export RESOURCE_GROUP=daily-cloud-photo-rg
   export LOCATION=eastus          # Flex Consumption 対応リージョン
   export APP_NAME=dailycloudphoto

   chmod +x deploy.sh && ./deploy.sh
   ```
3. 出力された API エンドポイント URL をアプリに入力。

`deploy.sh` はラッパーです。**Bicep** がインフラを構築し、**Microsoft Graph** が
アプリ登録を設定し、**OneDeploy** が Flex Consumption のデプロイコンテナへコードを
公開します（従来の `config-zip` コンテンツ共有方式には依存しません）。

### 設定

デプロイは `deploy.sh` が参照する環境変数と、Bicep パラメータ
（`bicep/main.bicepparam`）で構成します。

| 設定 | デフォルト | 説明 |
|------|-----------|------|
| `ENTRA_TENANT_SUBDOMAIN` | (必須) | 外部テナントのサブドメイン |
| `ENTRA_TENANT_ID` | (必須) | 外部テナント（ディレクトリ）GUID |
| `ENTRA_CLIENT_ID` | (自動作成) | アプリ登録のクライアント ID。再利用時に指定 |
| `RESOURCE_GROUP` | `daily-cloud-photo-rg` | 対象リソースグループ |
| `LOCATION` | `eastus` | Azure リージョン（Flex Consumption） |
| `APP_NAME` | `dailycloudphoto` | リソース名のベース |
| `entraScopes` (Bicep) | `openid offline_access` | トークンスコープ |
| `requireEmail` (Bicep) | `true` | サインアップ時にメール必須 |
| `enableShareUrl` (Bicep) | `true` | アップロード URL 共有機能 |
| `enableShareDownloadUrl` (Bicep) | `true` | ダウンロード URL 共有機能 |
| `enableLabelSharing` (Bicep) | `true` | ラベル共有機能 |
| `shareUploadUrlExpiryHours` (Bicep) | `24` | アップロード URL の有効期限（時間） |
| `shareDownloadUrlExpiryHours` (Bicep) | `72` | ダウンロード URL の有効期限（時間） |
| `maximumInstanceCount` (Bicep) | `100` | Flex Consumption の最大インスタンス数 |
| `instanceMemoryMB` (Bicep) | `2048` | Flex Consumption のインスタンスメモリ |
| `pythonVersion` (Bicep) | `3.11` | Python ランタイムバージョン |

### デプロイの流れ

```
./deploy.sh
   ├─ Bicep デプロイ (bicep/main.bicep)
   │     ├─ マネージド ID + 最小権限 RBAC
   │     ├─ Storage（photos + デプロイ用コンテナ）
   │     ├─ Cosmos DB（users マッピング + photos）
   │     └─ Flex Consumption Function App + App Insights
   ├─ Microsoft Graph
   │     └─ アプリ登録（パブリッククライアント / ネイティブ認証）
   ├─ OneDeploy（関数コード、リモートビルド）
   └─ Event Grid サブスクリプション（サムネイル生成）→ API エンドポイント
```

### アプリでの接続

1. **設定** → エンドポイント URL を入力 → **保存**
2. **接続テスト** で確認
3. **ログイン** → アカウント作成（メール + パスワード）→ **メール OTP** を入力

### リソースの削除

[![Open in Cloud Shell](https://img.shields.io/badge/Azure-Cloud_Shell-blue?logo=microsoftazure)](https://shell.azure.com)

```bash
az group delete --name daily-cloud-photo-rg --yes --no-wait
```

外部テナントに作成されたユーザーは、Entra 管理センター（または Microsoft Graph）で
別途削除します。

### アーキテクチャ

```
ユーザー → Azure Functions (HTTP, Flex Consumption) → ルートディスパッチ
          ├── Entra External ID（ネイティブ認証）: signup / OTP / signin / SSPR
          │        （バックエンドは資格情報を中継し、トークンは Entra が発行）
          ├── 保護エンドポイントでトークン検証（Entra JWKS, RS256）
          ├── Blob Storage（写真保存 + サムネイル、SAS URL）
          ├── Cosmos DB — users: username → email / Entra オブジェクト ID マッピング
          │             — photos: メタデータ（Entra ユーザー ID でパーティション）
          └── Blob（Event Grid）トリガー → EXIF 解析 + サムネイル生成
```

- 認証は完全に Entra External ID へ委譲（bcrypt なし・JWT シークレットなし・
  リセット/確認コードの保存なし）。
- `users` コンテナは `username → email / entraObjectId` のマッピングのみを保存し、
  ユーザー名ログインとラベル共有を維持します。ステートレスな `/auth/signup` と
  `/auth/confirm` の間だけ、短命の不透明な `continuation_token`（資格情報ではなく
  フローハンドル）を一時的に保存します。
- プラットフォームストレージ（ホスト + デプロイパッケージ）は**マネージド ID**を使用。
  写真のデータプレーンアクセスは SAS 生成のため接続文字列を使用。
- ユーザーの写真は `users/{uid}/`（`uid` は安定した Entra ID）で分離。

### API 契約（アプリ側は変更なし）

| エンドポイント | リクエスト | レスポンス |
|----------------|-----------|-----------|
| `POST /auth/signup` | `{username, password, email}` | `{confirmationRequired: true}` |
| `POST /auth/confirm` | `{username, confirmationCode}` | `{message}` |
| `POST /auth/signin` | `{username, password}` | `{accessToken, refreshToken, expiresIn}` |
| `POST /auth/refresh` | `{refreshToken}` | `{accessToken, refreshToken, expiresIn}` |
| `POST /auth/forgot-password` | `{username}` | `{message}`（存在有無を返さない） |
| `POST /auth/reset-password` | `{username, confirmationCode, newPassword}` | `{message}` |

### コスト目安

すべてサーバーレス従量課金。少量利用なら非常に安価。

以下はあくまで目安です。実際の費用は利用状況により異なります。各クラウドプロバイダーの
請求ダッシュボードを定期的に確認してください。

| サービス | 無料枠 |
|----------|--------|
| Azure Functions (Flex Consumption) | 毎月の無料実行時間枠 |
| Cosmos DB（サーバーレス） | 消費した要求ユニット分の従量課金 |
| Blob Storage | ~$0.02/GB/月（ホット層） |
| Application Insights | 月5 GB |
| Entra External ID | 月間アクティブユーザーの無料枠 |

### 本番運用時のセキュリティ推奨事項

以下は一例であり、これだけで十分というわけではありません。要件に応じて追加の対策を
検討してください。

- **マネージド ID の徹底**: Cosmos DB もデータプレーン RBAC で MI 化し、接続文字列を排除。
- **ネットワーク制限**: Cosmos DB と Storage に Azure Private Endpoints を使用
  ([docs](https://learn.microsoft.com/ja-jp/azure/cosmos-db/how-to-configure-private-endpoints))。
- **WAF**: Azure Front Door + WAF を Function App の前に配置
  ([docs](https://learn.microsoft.com/ja-jp/azure/web-application-firewall/overview))。
- **CORS の制限**: 許可するオリジンを特定ドメインに限定。
- **レート制限**: Azure API Management またはカスタムミドルウェアで設定。
- **条件付きアクセス / MFA**: 外部テナントのユーザーに MFA を強制。
- **共有 URL の制限**: ファイルサイズ制限、アップロード回数制限、Content-Type 検証を検討。
