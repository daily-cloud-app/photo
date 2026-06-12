"""
S3 イベントトリガー:
1. ファイルが PUT されたら DynamoDB にメタデータを自動登録
2. サムネイル画像（200px）を生成して thumbnails/ に保存
"""
import io
import os
import urllib.parse
from datetime import datetime, timezone

import boto3
from PIL import Image

PHOTOS_TABLE = os.environ.get('PHOTOS_TABLE', '')
THUMBNAIL_SIZE = (200, 200)

dynamodb = boto3.resource('dynamodb')
s3_client = boto3.client('s3')


def handler(event, context):
    table = dynamodb.Table(PHOTOS_TABLE)

    for record in event.get('Records', []):
        bucket = record['s3']['bucket']['name']
        key = urllib.parse.unquote_plus(record['s3']['object']['key'])
        size = record['s3']['object'].get('size', 0)

        # thumbnails/ プレフィックスのファイルは無視（無限ループ防止）
        if key.startswith('thumbnails/'):
            continue

        # パスから userId を抽出
        parts = key.split('/')
        if len(parts) < 3 or parts[0] != 'users':
            continue

        user_id = parts[1]
        photo_id = parts[-1]

        # 拡張子からコンテンツタイプを推定
        ext = photo_id.rsplit('.', 1)[-1].lower() if '.' in photo_id else ''
        content_type_map = {
            'jpg': 'image/jpeg',
            'jpeg': 'image/jpeg',
            'png': 'image/png',
            'gif': 'image/gif',
            'webp': 'image/webp',
            'heic': 'image/heic',
            'heif': 'image/heic',
        }
        content_type = content_type_map.get(ext, 'application/octet-stream')

        # サムネイル生成 + EXIF から撮影日時を取得
        thumbnail_key = f"thumbnails/{key.removeprefix('users/')}"
        exif_date = None
        try:
            exif_date = _generate_thumbnail_and_get_date(bucket, key, thumbnail_key)
            print(f'Thumbnail generated: {thumbnail_key}')
            if exif_date:
                print(f'EXIF date: {exif_date}')
        except Exception as e:
            print(f'Thumbnail generation failed for {key}: {e}')
            thumbnail_key = None

        # 撮影日時: EXIF > 現在時刻
        created_at = exif_date if exif_date else datetime.now(timezone.utc).isoformat()

        # DynamoDB にメタデータを登録/更新
        existing = table.get_item(Key={'userId': user_id, 'photoId': photo_id})
        if 'Item' in existing:
            # 既存レコードがあれば thumbnailKey を更新
            update_expr = 'SET #s = :status, #sz = :size'
            expr_names = {'#s': 'status', '#sz': 'size'}
            expr_values = {':status': 'uploaded', ':size': size}
            if thumbnail_key:
                update_expr += ', thumbnailKey = :tk'
                expr_values[':tk'] = thumbnail_key
            table.update_item(
                Key={'userId': user_id, 'photoId': photo_id},
                UpdateExpression=update_expr,
                ExpressionAttributeNames=expr_names,
                ExpressionAttributeValues=expr_values,
            )
        else:
            # 新規登録（S3 に直接入れた場合）
            item = {
                'userId': user_id,
                'photoId': photo_id,
                'filename': photo_id,
                'contentType': content_type,
                's3Key': key,
                'size': size,
                'status': 'uploaded',
                'createdAt': created_at,
                'labels': [],
            }
            if thumbnail_key:
                item['thumbnailKey'] = thumbnail_key
            table.put_item(Item=item)

        print(f'Processed: {key} for user {user_id}')


def _generate_thumbnail_and_get_date(bucket, source_key, thumbnail_key):
    """S3 から画像を取得してサムネイルを生成し、EXIF から撮影日時を返す"""
    response = s3_client.get_object(Bucket=bucket, Key=source_key)
    image_data = response['Body'].read()

    img = Image.open(io.BytesIO(image_data))

    # EXIF から撮影日時を取得
    exif_date = None
    try:
        exif = img.getexif()
        if exif:
            # DateTime (306) or DateTimeOriginal (36867)
            date_str = exif.get(306) or exif.get(36867)
            if date_str:
                # "2026:05:05 14:30:00" → ISO format
                dt = datetime.strptime(date_str, '%Y:%m:%d %H:%M:%S')
                exif_date = dt.replace(tzinfo=timezone.utc).isoformat()
    except Exception as e:
        print(f'EXIF extraction failed: {e}')

    # サムネイル生成
    img.thumbnail(THUMBNAIL_SIZE, Image.LANCZOS)

    buffer = io.BytesIO()
    if img.mode in ('RGBA', 'P'):
        img = img.convert('RGB')
    img.save(buffer, format='JPEG', quality=80)
    buffer.seek(0)

    s3_client.put_object(
        Bucket=bucket,
        Key=thumbnail_key,
        Body=buffer.getvalue(),
        ContentType='image/jpeg',
    )

    return exif_date
