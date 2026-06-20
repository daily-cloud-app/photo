# Daily Cloud Photo — Azure バックエンド

> Azure アカウントが必要です（[無料で作成](https://azure.microsoft.com/free/)）

## ワンクリックデプロイ

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fdaily-cloud-app%2Fphoto%2Fmain%2Fazure%2Fazuredeploy.json)

### クイックスタート

1. 上記の **Deploy to Azure** ボタンをクリック
2. パラメータを入力（デフォルトのままでOK） → **確認および作成** → **作成**
3. デプロイ完了後（約3〜5分）、**出力** タブ → `functionAppName` をコピー
4. 関数コードをデプロイ:
   ```bash
   cd function_app
   func azure functionapp publish <functionAppName> --python
   ```
5. 出力タブの `apiEndpoint` をアプリに入力

---

## パラメータ一覧

| パラメータ | デフォルト | 説明 |
|-----------|-----------|------|
| appName | `dailycloudphoto` | 全リソースのベース名 |
| location | リソースグループのリージョン | Azure リージョン |
| jwtSecret | 自動生成 | JWT 署名用のシークレットキー |
| accessTokenExpireMinutes | `60` | アクセストークンの有効期限（分） |
| refreshTokenExpireDays | `30` | リフレッシュトークンの有効期限（日） |
| requireEmail | `true` | サインアップ時にメール必須 |
| requirePhone | `false` | サインアップ時に電話番号必須 |
| enableShareUrl | `true` | アップロードURL共有機能 |
| enableLabelSharing | `true` | ラベル共有機能 |
| appDisplayName | `Daily Cloud Photo Backend` | /info で返される表示名 |

## アプリでの接続

1. ドロワー → **設定** → エンドポイント URL を入力 → **保存**
2. **接続テスト** で確認
3. ドロワー → **ログイン** からアカウント作成

## リソースの削除

```bash
az group delete --name daily-cloud-photo-rg --yes --no-wait
```

> これにより全データ（写真、ユーザー、メタデータ）が完全に削除されます。

## アーキテクチャ

```
ユーザー → Azure Functions (HTTP) → メインハンドラー (ルートディスパッチ)
                                        ├── カスタム JWT 認証 (bcrypt + PyJWT)
                                        ├── Blob Storage (写真保存 + サムネイル)
                                        ├── Cosmos DB (メタデータ)
                                        └── Blob Trigger 関数 (EXIF + サムネイル生成)
```

- 全 API を1つの Function App で処理（パスベースのルーティング）
- ユーザーの写真は `users/{uid}/` プレフィックスで分離
- SAS URL で Blob Storage に直接アップロード（関数を経由しない）
- Blob トリガーで自動的に EXIF 解析 + サムネイル生成

## コスト目安

全サービスがサーバーレス/従量課金です。使用量が少なければ非常に安価です。

上記はあくまで目安です。実際の費用は利用状況により異なります。各クラウドプロバイダーの請求ダッシュボードを定期的に確認してください。

| サービス | 無料枠 |
|---------|--------|
| Azure Functions | 月100万実行 |
| Cosmos DB | 最初の 1000 RU/s 無料枠あり |
| Blob Storage | 約 $0.02/GB/月 (Hot tier) |
| Application Insights | 月5 GB |

**個人利用（写真1,000枚未満）の月額目安:** $1〜5/月

## 本番運用時のセキュリティ推奨事項

テンプレートには基本的なセキュリティ（HTTPS のみ、Blob のパブリックアクセス無効、TLS 1.2）が含まれています。本番運用する場合は以下も検討してください:

- **JWT シークレットのローテーション**: JWT_SECRET アプリ設定を定期的にローテーション
- **ネットワーク制限**: Cosmos DB に Azure Private Endpoints を使用
- **WAF**: Function App の前に Azure Front Door + WAF を配置
- **CORS の制限**: 許可するオリジンを特定ドメインに限定
- **レート制限**: Azure API Management またはカスタムミドルウェアで設定
- **Key Vault**: シークレットをアプリ設定ではなく Azure Key Vault に保存
- **共有URLの制限**: ファイルサイズ制限、アップロード回数制限、Content-Type 検証の追加を検討
