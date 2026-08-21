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

### What `deploy.sh` automates

`deploy.sh` provisions and configures everything, including the External ID
tenant and its user flow. No manual portal steps are required for a standard
setup. It performs:

- **External ID tenant** creation via Bicep (`ciamDirectories`) — opt-in with
  `CREATE_TENANT=true`. Reuse an existing tenant instead by passing
  `ENTRA_TENANT_ID`.
- **App registration** (public client + native authentication) via Microsoft Graph.
- **Email OTP** authentication method enabled tenant-wide (required for SSPR).
- **Sign-up/sign-in user flow** (Email + Password) created via Graph and
  **associated with the app** — no portal step.
- **Infrastructure** (Storage, Cosmos DB, managed identity, Flex Consumption
  Function App) via Bicep, then the function code via **OneDeploy**.

The Email OTP policy and user flow require Graph scopes that the Azure CLI's
first-party token does not carry. To handle this, `deploy.sh` provisions a
**temporary Graph automation app** with application permissions
(`Policy.ReadWrite.AuthenticationMethod`, `EventListener.ReadWrite.All`,
`Application.ReadWrite.All`), grants admin consent, uses its client-credentials
token for those calls, and **deletes the app** at the end of Step 3 (no standing
credential is left behind).

> [!NOTE]
> The `ciamDirectories` resource type is preview-only and requires a **delegated
> user sign-in** (a managed identity or service principal cannot create it).
> Creating the tenant and configuring it on a different tenant may require **up
> to two interactive `az login` prompts**. The signed-in user must be able to
> create the resource in the subscription and must be a **Global Administrator**
> (or hold Privileged Role Administrator + Application Administrator) on the
> external tenant, since the script creates an app and grants admin consent there.

### Prerequisites

- Azure CLI (`az`) signed in as a **user** (not a service principal).
- `zip`, `curl`, `python3` (pre-installed in Cloud Shell).
- A subscription in which resources (including the CIAM directory) can be created.
- **Global Administrator** on the external tenant (needed to grant admin consent
  to the temporary Graph automation app).

### Quick Start

[![Open in Cloud Shell](https://img.shields.io/badge/Azure-Cloud_Shell-blue?logo=microsoftazure)](https://shell.azure.com)

1. Click the **Cloud Shell** button above.
2. Clone and deploy. Choose one of the two modes below.

   **A) Create a brand-new External ID tenant (fully automated):**
   ```bash
   [ -d photo ] || git clone https://github.com/daily-cloud-app/photo.git
   cd photo && git checkout -- . && git pull --ff-only && cd azure

   export CREATE_TENANT=true          # provision a new external tenant
   # Optional overrides (defaults shown):
   export RESOURCE_GROUP=daily-cloud-photo-rg
   export LOCATION=eastus             # must be a Flex Consumption region
   export APP_NAME=dailycloudphoto

   chmod +x deploy.sh && ./deploy.sh
   ```

   **B) Use an existing External ID tenant:**
   ```bash
   [ -d photo ] || git clone https://github.com/daily-cloud-app/photo.git
   cd photo && git checkout -- . && git pull --ff-only && cd azure

   export ENTRA_TENANT_ID=<tenant-guid>
   # Optional: skip tenant subdomain lookup / app creation by providing them.
   # export ENTRA_TENANT_SUBDOMAIN=<yourtenant>
   # export ENTRA_CLIENT_ID=<app-client-id>

   chmod +x deploy.sh && ./deploy.sh
   ```
3. When prompted, complete the one-time interactive sign-in to the external
   tenant, then copy the API endpoint URL from the output into the app.

`deploy.sh` is a thin wrapper: **Bicep** provisions the tenant and
infrastructure, **Microsoft Graph** configures the app registration, Email OTP
policy and user flow, and **OneDeploy** publishes the code to the Flex
Consumption deployment container (no legacy `config-zip` content-share flow).

### Configuration

Deployment is configured through environment variables consumed by `deploy.sh`,
and Bicep parameters (`bicep/main.bicepparam`).

| Setting | Default | Description |
|---------|---------|-------------|
| `CREATE_TENANT` | `false` | Set `true` to create a new External ID tenant |
| `ENTRA_TENANT_ID` | (auto/created) | Existing external tenant GUID; skips tenant creation when set |
| `ENTRA_TENANT_SUBDOMAIN` | (auto-resolved) | External tenant subdomain; resolved from the tenant when omitted |
| `ENTRA_CLIENT_ID` | (auto-created) | App registration client ID; set to reuse |
| `TENANT_DISPLAY_NAME` | `Daily Cloud Photo External ID` | New tenant display name (when creating) |
| `TENANT_DATA_LOCATION` | `United States` | New tenant data residency location |
| `TENANT_COUNTRY_CODE` | `US` | New tenant country code |
| `ENTRA_USER_FLOW_NAME` | `DailyCloudPhotoSignUpSignIn` | Sign-up/sign-in user flow name |
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
   ├─ [CREATE_TENANT=true] Bicep deploy (bicep/identity_tenant.bicep)
   │     └─ External ID (CIAM) tenant   ← delegated user token
   ├─ One-time interactive sign-in to the external tenant (if needed)
   ├─ Microsoft Graph (external tenant)
   │     ├─ App registration (public client + native auth enabled)
   │     ├─ Email OTP authentication method (SSPR prerequisite)
   │     └─ Sign-up/sign-in user flow (Email+Password) + app association
   ├─ Bicep deploy (bicep/main.bicep)   ← subscription context
   │     ├─ Managed Identity + least-privilege RBAC
   │     ├─ Storage (photos + deployment container)
   │     ├─ Cosmos DB (users mapping + photos)
   │     └─ Flex Consumption Function App + App Insights
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

### `deploy.sh` が自動化する範囲

`deploy.sh` は External ID テナントとユーザーフローを含め、すべてを自動で構築・設定
します。標準的なセットアップではポータルでの手動作業は不要です。実行内容:

- **External ID テナント**作成（Bicep `ciamDirectories`）: `CREATE_TENANT=true` で
  オプトイン。既存テナントを使う場合は `ENTRA_TENANT_ID` を指定してスキップ。
- **アプリ登録**（パブリッククライアント + ネイティブ認証）を Microsoft Graph で作成。
- **メール OTP** 認証メソッドをテナント全体で有効化（SSPR の前提）。
- **サインアップ/サインイン ユーザーフロー**（メール + パスワード）を Graph で作成し、
  **アプリに関連付け**（ポータル操作なし）。
- **インフラ**（Storage・Cosmos DB・マネージド ID・Flex Consumption Function App）を
  Bicep で構築し、関数コードを **OneDeploy** で公開。

メール OTP ポリシーとユーザーフローの設定には、Azure CLI の第一者トークンが持たない
Graph スコープが必要です。そのため `deploy.sh` は**一時的な Graph 自動化アプリ**を
アプリケーション権限（`Policy.ReadWrite.AuthenticationMethod`・
`EventListener.ReadWrite.All`・`Application.ReadWrite.All`）付きで作成し、管理者同意を
付与、そのクライアント資格情報トークンで上記を実行し、**Step 3 の最後にアプリを削除**
します（資格情報は残しません）。

> [!NOTE]
> `ciamDirectories` リソースはプレビュー版で、作成には**ユーザーの委任サインイン**が
> 必要です（マネージド ID・サービスプリンシパルでは作成不可）。テナント作成と、別
> テナント上での設定のため、**対話ログインが最大2回**必要になる場合があります。
> サインインユーザーはサブスクリプションでリソースを作成でき、かつ外部テナントで
> **グローバル管理者**（または特権ロール管理者 + アプリケーション管理者）である必要が
> あります（スクリプトがアプリを作成し管理者同意を付与するため）。

### 前提

- Azure CLI (`az`) に**ユーザー**としてサインイン済み（サービスプリンシパル不可）。
- `zip`・`curl`・`python3`（Cloud Shell にプリインストール済み）。
- CIAM ディレクトリを含むリソースを作成できるサブスクリプション。
- 外部テナントの**グローバル管理者**（一時 Graph 自動化アプリへの管理者同意付与に必要）。

### クイックスタート

[![Open in Cloud Shell](https://img.shields.io/badge/Azure-Cloud_Shell-blue?logo=microsoftazure)](https://shell.azure.com)

1. 上記の **Cloud Shell** ボタンをクリック。
2. クローンしてデプロイ。以下の2モードから選択します。

   **A) External ID テナントを新規作成（完全自動）:**
   ```bash
   [ -d photo ] || git clone https://github.com/daily-cloud-app/photo.git
   cd photo && git checkout -- . && git pull --ff-only && cd azure

   export CREATE_TENANT=true          # 外部テナントを新規作成
   # 任意の上書き（デフォルト値）:
   export RESOURCE_GROUP=daily-cloud-photo-rg
   export LOCATION=eastus             # Flex Consumption 対応リージョン
   export APP_NAME=dailycloudphoto

   chmod +x deploy.sh && ./deploy.sh
   ```

   **B) 既存の External ID テナントを使用:**
   ```bash
   [ -d photo ] || git clone https://github.com/daily-cloud-app/photo.git
   cd photo && git checkout -- . && git pull --ff-only && cd azure

   export ENTRA_TENANT_ID=<tenant-guid>
   # 任意: サブドメイン解決やアプリ作成を省略する場合は指定
   # export ENTRA_TENANT_SUBDOMAIN=<yourtenant>
   # export ENTRA_CLIENT_ID=<app-client-id>

   chmod +x deploy.sh && ./deploy.sh
   ```
3. 途中で外部テナントへの1回きりの対話サインインを求められたら完了させ、出力された
   API エンドポイント URL をアプリに入力。

`deploy.sh` はラッパーです。**Bicep** がテナントとインフラを構築し、**Microsoft Graph**
がアプリ登録・メール OTP ポリシー・ユーザーフローを設定し、**OneDeploy** が Flex
Consumption のデプロイコンテナへコードを公開します（従来の `config-zip` コンテンツ
共有方式には依存しません）。

### 設定

デプロイは `deploy.sh` が参照する環境変数と、Bicep パラメータ
（`bicep/main.bicepparam`）で構成します。

| 設定 | デフォルト | 説明 |
|------|-----------|------|
| `CREATE_TENANT` | `false` | `true` で External ID テナントを新規作成 |
| `ENTRA_TENANT_ID` | (自動/作成) | 既存外部テナント GUID。指定時はテナント作成をスキップ |
| `ENTRA_TENANT_SUBDOMAIN` | (自動解決) | 外部テナントのサブドメイン。未指定ならテナントから解決 |
| `ENTRA_CLIENT_ID` | (自動作成) | アプリ登録のクライアント ID。再利用時に指定 |
| `TENANT_DISPLAY_NAME` | `Daily Cloud Photo External ID` | 新規テナントの表示名（作成時） |
| `TENANT_DATA_LOCATION` | `United States` | 新規テナントのデータ所在地 |
| `TENANT_COUNTRY_CODE` | `US` | 新規テナントの国コード |
| `ENTRA_USER_FLOW_NAME` | `DailyCloudPhotoSignUpSignIn` | サインアップ/サインイン ユーザーフロー名 |
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
   ├─ [CREATE_TENANT=true] Bicep デプロイ (bicep/identity_tenant.bicep)
   │     └─ External ID (CIAM) テナント   ← ユーザー委任トークン
   ├─ 外部テナントへの1回きりの対話サインイン（必要な場合）
   ├─ Microsoft Graph（外部テナント）
   │     ├─ アプリ登録（パブリッククライアント + ネイティブ認証有効化）
   │     ├─ メール OTP 認証メソッド（SSPR の前提）
   │     └─ サインアップ/サインイン ユーザーフロー（メール+パスワード）+ アプリ関連付け
   ├─ Bicep デプロイ (bicep/main.bicep)   ← サブスクリプション文脈
   │     ├─ マネージド ID + 最小権限 RBAC
   │     ├─ Storage（photos + デプロイ用コンテナ）
   │     ├─ Cosmos DB（users マッピング + photos）
   │     └─ Flex Consumption Function App + App Insights
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
