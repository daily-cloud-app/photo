# Daily Cloud Photo — API Reference

REST API specification that all cloud provider backends must implement.

## Base URL

Endpoint URL generated after deployment.  
Example: `https://xxxxxxxxxx.execute-api.ap-northeast-1.amazonaws.com/v1`

## Authentication

Token-based authentication. Use the `accessToken` from signin response:
```
Authorization: Bearer <accessToken>
```

---

## Server Info

### GET /info

Returns server configuration. No authentication required.

**Response 200:**
```json
{
  "name": "Daily Cloud Photo Backend",
  "version": "1.0.0",
  "signupFields": ["username", "password", "email"],
  "features": ["upload", "labels", "share-url", "label-sharing"]
}
```

- `signupFields`: Fields required for signup (dynamic based on server config)
- `features`: Enabled features. Possible values: `upload`, `labels`, `share-url`, `label-sharing`

---

## Auth

### POST /auth/signup

Register a new user.

**Request Body:**
```json
{
  "username": "string (required)",
  "password": "string (required)",
  "email": "string (required when server configured with RequireEmail=true)",
  "phone": "string (required when server configured with RequirePhone=true)"
}
```

**Response 201:**
```json
{
  "message": "User created. Confirmation may be required.",
  "confirmationRequired": true
}
```

### POST /auth/confirm

Confirm signup with verification code.

**Request Body:**
```json
{
  "username": "string",
  "confirmationCode": "string"
}
```

**Response 200:**
```json
{
  "message": "User confirmed."
}
```

### POST /auth/signin

Sign in and receive tokens.

**Request Body:**
```json
{
  "username": "string",
  "password": "string"
}
```

**Response 200:**
```json
{
  "accessToken": "string",
  "refreshToken": "string",
  "expiresIn": 3600
}
```

### POST /auth/refresh

Refresh an expired access token.

**Request Body:**
```json
{
  "refreshToken": "string"
}
```

**Response 200:**
```json
{
  "accessToken": "string",
  "expiresIn": 3600
}
```

### POST /auth/forgot-password

Request a password reset code.

**Request Body:**
```json
{
  "username": "string"
}
```

**Response 200:**
```json
{
  "message": "Confirmation code sent."
}
```

### POST /auth/reset-password

Reset password with confirmation code.

**Request Body:**
```json
{
  "username": "string",
  "confirmationCode": "string",
  "newPassword": "string"
}
```

**Response 200:**
```json
{
  "message": "Password reset successful."
}
```

---

## Photos

### GET /photos

List photos for the authenticated user. Includes shared photos from other users.

**Query Parameters:**
- `limit` (int, optional, default: 100)
- `cursor` (string, optional) — pagination cursor

**Response 200:**
```json
{
  "photos": [
    {
      "id": "string",
      "filename": "string",
      "contentType": "image/jpeg",
      "size": 1234567,
      "createdAt": "2025-01-01T00:00:00Z",
      "thumbnailUrl": "string (presigned URL, 1hr expiry)",
      "fullUrl": "string (presigned URL, 1hr expiry)",
      "labels": ["custom:123", "year:2025"],
      "shared": false,
      "sharedFrom": ""
    }
  ],
  "nextCursor": "string | null"
}
```

Shared photos have `"shared": true` and `"sharedFrom": "email@example.com"`.

### GET /photos/{id}

Get a single photo's metadata and fresh presigned URLs.

**Response 200:**
```json
{
  "id": "string",
  "filename": "string",
  "contentType": "image/jpeg",
  "size": 1234567,
  "createdAt": "2025-01-01T00:00:00Z",
  "fullUrl": "string (presigned URL)",
  "thumbnailUrl": "string (presigned URL)"
}
```

### POST /photos/upload-url

Get a presigned URL for uploading a photo.

**Request Body:**
```json
{
  "filename": "IMG_20250101_120000.jpg",
  "contentType": "image/jpeg",
  "createdAt": "2025-01-01T12:00:00Z (optional)",
  "photoId": "string (optional, for re-upload)"
}
```

**Response 200:**
```json
{
  "photoId": "string",
  "uploadUrl": "string (presigned PUT URL)",
  "expiresIn": 3600
}
```

### POST /photos/{id}/confirm

Confirm that upload to presigned URL is complete.

**Response 200:**
```json
{
  "message": "Upload confirmed.",
  "thumbnailUrl": "string (presigned URL)"
}
```

### PUT /photos/{id}/labels

Update labels for a photo.

**Request Body:**
```json
{
  "labels": ["custom:123", "custom:456"]
}
```

**Response 200:**
```json
{
  "message": "Labels updated.",
  "labels": ["custom:123", "custom:456"]
}
```

### DELETE /photos/{id}

Soft-delete a photo (marks as deleted, S3 data preserved).

**Response 200:**
```json
{
  "message": "Photo deleted."
}
```

---

## Share Upload URL

### POST /photos/share-upload-url

Generate a temporary upload page URL for third parties. Requires `share-url` feature enabled.

**Request Body:**
```json
{
  "expiresHours": 24
}
```

**Response 200:**
```json
{
  "shareUrl": "https://api.example.com/v1/upload-page?token=uuid",
  "token": "string",
  "expiresHours": 24
}
```

### GET /upload-page?token={token}

Returns an HTML upload page. No authentication required. Token validated server-side.

### POST /photos/share-upload

Get a presigned URL using a share token (no auth required). Requires `share-url` feature enabled.

**Request Body:**
```json
{
  "token": "string",
  "filename": "photo.jpg",
  "contentType": "image/jpeg"
}
```

**Response 200:**
```json
{
  "uploadUrl": "string (presigned PUT URL)",
  "photoId": "string"
}
```

---

## Label Sharing

Requires `label-sharing` feature enabled.

### POST /shares

Create a label share request.

**Request Body:**
```json
{
  "toUsername": "recipient@example.com",
  "labelId": "custom:123",
  "labelName": "Family"
}
```

**Response 201:**
```json
{
  "message": "Share request created.",
  "shareId": "string"
}
```

### GET /shares/pending

List pending (not yet accepted) share requests received.

**Response 200:**
```json
{
  "shares": [
    {
      "shareId": "string",
      "fromUser": "sender@example.com",
      "labelId": "custom:123",
      "labelName": "Family",
      "createdAt": "2025-01-01T00:00:00Z"
    }
  ]
}
```

### GET /shares

List accepted shares (labels shared with you).

**Response 200:**
```json
{
  "shares": [
    {
      "shareId": "string",
      "fromUser": "sender@example.com",
      "fromUserId": "string",
      "labelId": "custom:123",
      "labelName": "Family",
      "createdAt": "2025-01-01T00:00:00Z"
    }
  ]
}
```

### GET /shares/sent

List shares you have sent to others.

**Response 200:**
```json
{
  "shares": [
    {
      "shareId": "string",
      "toUser": "recipient@example.com",
      "labelId": "custom:123",
      "labelName": "Family",
      "status": "active",
      "createdAt": "2025-01-01T00:00:00Z"
    }
  ]
}
```

### POST /shares/{shareId}/accept

Accept a pending share request.

**Response 200:**
```json
{
  "message": "Share accepted."
}
```

### POST /shares/{shareId}/reject

Reject a pending share request.

**Response 200:**
```json
{
  "message": "Share rejected."
}
```

### DELETE /shares/{shareId}

Remove a share (works for both sender and receiver). Bidirectional cleanup.

**Response 200:**
```json
{
  "message": "Share removed."
}
```

---

## Error Responses

All endpoints return errors in this format:

```json
{
  "error": "ErrorCode",
  "message": "Human readable description"
}
```

**HTTP Status Codes:**
- 400 — Validation error
- 401 — Authentication error (invalid/expired token)
- 403 — Forbidden (feature disabled, token expired)
- 404 — Resource not found
- 409 — Conflict (e.g. username already exists)
- 429 — Rate limited
- 500 — Server error
