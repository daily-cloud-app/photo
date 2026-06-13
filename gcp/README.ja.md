# Daily Cloud Photo — GCP バックエンド

## ワンクリックデプロイ

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https://github.com/daily-cloud-app/photo&cloudshell_working_dir=gcp&cloudshell_tutorial=README.md&cloudshell_open_in_editor=main.py)

---

## クイックデプロイ

1. 上記の **Open in Cloud Shell** ボタンをクリック
2. デプロイスクリプトを実行:
   ```bash
   chmod +x deploy.sh && ./deploy.sh
   ```
3. 出力から API エンドポイント URL をコピー

---

## パラメータ一覧

| パラメータ | デフォルト | 説明 |
|-----------|-----------|------|
| `PROJECT_ID` | (現在のプロジェクト) | GCP プロジェクト ID |
| `REGION` | `asia-northeast1` | デプロイリージョン |
| `BUCKET_NAME` | `{project}-photos` | 写真用 Cloud Storage バケット |
| `REQUIRE_EMAIL` | `true` | サインアップ時にメール必須 |
| `REQUIRE_PHONE` | `false` | サインアップ時に電話番号必須 |
| `ENABLE_SHARE_URL` | `true` | アップロードURL共有機能 |
| `ENABLE_LABEL_SHARING` | `true` | ラベル共有機能 |

---

## アプリでの接続

4. ドロワー → **設定** → エンドポイント URL を貼り付け → **保存**
5. **接続テスト** で確認
6. ドロワー → **ログイン** からアカウント作成

---

## アーキテクチャ

```
ユーザー → Cloud Functions (HTTP) → メインハンドラー (Flask ルーティング)
                                        ├── Firebase Auth (ユーザー管理)
                                        ├── Cloud Storage (写真保存 + サムネイル)
                                        ├── Firestore (メタデータ)
                                        └── Storage Trigger 関数 (EXIF + サムネイル)
```

- 全 API を1つの Cloud Function で処理（Flask ベースのパスルーティング）
- ユーザーの写真は `users/{firebase_uid}/` プレフィックスで分離
- 署名付き URL で Cloud Storage に直接アップロード（関数を経由しない）
- ストレージトリガーで自動的に EXIF 解析 + サムネイル生成

---

## Firestore データモデル

```
Collection: photos
  Document ID: {userId}_{photoId}
  Fields:
    - userId: string
    - photoId: string
    - filename: string
    - contentType: string
    - gcsKey: string
    - size: number
    - status: string (uploading | uploaded | deleted)
    - createdAt: string (ISO 8601)
    - labels: array of strings
    - thumbnailKey: string (optional)
    - deletedAt: string (optional)

  Special document types (same collection):
    - share_token:{token} — 共有アップロードトークン
    - share:{shareId} — 受信した共有
    - sent_share:{shareId} — 送信した共有
```

---

## リソースの削除

```bash
# 関数の削除
gcloud functions delete daily-cloud-photo-api --region=${REGION} --gen2 -q
gcloud functions delete daily-cloud-photo-storage-trigger --region=${REGION} --gen2 -q

# ストレージバケットの削除（警告: 全ての写真が削除されます）
gsutil -m rm -r gs://${BUCKET_NAME}
gsutil rb gs://${BUCKET_NAME}

# Firestore データの削除（オプション）
gcloud firestore databases delete --database="(default)"
```

---

## コスト目安

すべて従量課金。少人数であれば GCP 無料枠内に収まります。

上記はあくまで目安です。実際の費用は利用状況により異なります。各クラウドプロバイダーの請求ダッシュボードを定期的に確認してください。

| サービス | 無料枠 |
|----------|--------|
| Cloud Functions | 月200万呼び出し |
| Firestore | 1 GiB ストレージ、5万読み取り/日、2万書き込み/日 |
| Cloud Storage | 5 GB（Standard）、月5,000 Class A オペレーション |
| Firebase Auth | 50,000 MAU（電話認証: 月10,000件） |
| ネットワーク | 月1 GB エグレス |

---

## 本番運用時のセキュリティ推奨事項

- **IAM**: 最小権限のサービスアカウントを使用
- **VPC コネクタ**: 関数を VPC 内に配置し内部アクセスのみに制限
- **Cloud Armor**: Cloud Load Balancer の前に WAF ルールを追加
- **CORS**: 本番環境では許可するオリジンを制限
- **監査ログ**: 全 API 呼び出しに Cloud Audit Logs を有効化
- **レート制限**: Cloud Functions の同時実行数制限を設定
- **共有URLの制限**: ファイルサイズ制限と Content-Type 検証の追加
