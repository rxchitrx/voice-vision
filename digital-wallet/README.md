# Digital Wallet

A full-stack web application for managing personal finances with real-time balance tracking and transaction management.

## Features

- **Balance Management**: View your current wallet balance in real-time
- **Add Funds**: Easily deposit money into your wallet
- **Strict QR Payments**: Send money only to a backend-configured trusted merchant
- **Transaction History**: Track all your transactions with detailed records
- **Real-time Updates**: Balance automatically refreshes every 2 seconds
- **Telegram Notifications**: Get instant notifications for all transactions (optional)
- **MiniCPM Proxy API**: Optional perception endpoint for scene/text/document analysis

## Tech Stack

### Frontend
- **React 18.2.0** - UI framework
- **Axios 1.6.2** - HTTP client for API calls
- **CSS** - Styling

### Backend
- **Node.js** - Runtime environment
- **Express.js 4.18.2** - Web framework
- **MongoDB 8.0.3** - Database
- **Mongoose** - ODM for MongoDB
- **CORS** - Cross-origin resource sharing

## Prerequisites

- Node.js (v14 or higher)
- MongoDB (running locally or cloud instance)
- npm or yarn package manager

## Installation

### 1. Clone the repository

```bash
git clone <repository-url>
cd voice-vision
```

### 2. Install Backend Dependencies

```bash
cd backend
npm install
```

### 3. Configure Environment Variables

Create a `.env` file in the `backend` directory (use `.env.example` as a template):

```env
PORT=5001
MONGODB_URI=mongodb://localhost:27017/digital-wallet
TELEGRAM_BOT_TOKEN=your_bot_token_here  # Optional
TELEGRAM_CHAT_ID=your_chat_id_here      # Optional

# Strict payment config (single merchant)
PAYMENT_MERCHANT_ID=voicevision-demo-merchant
PAYMENT_MERCHANT_NAME=VoiceVision Demo Merchant
PAYMENT_RECIPIENT_PHONE=8290883601
PAYMENT_TRUSTED_QR_RAW=https://en.m.wikipedia.org
PAYMENT_MAX_PER_TXN=5000

# Optional MiniCPM proxy
MINICPM_API_URL=http://127.0.0.1:1234/v1/chat/completions
MINICPM_API_KEY=
MINICPM_TIMEOUT_MS=15000
MINICPM_PROVIDER=lmstudio
MINICPM_MODEL=mini-cpm-v-4
MINICPM_TEMPERATURE=0.2
MINICPM_MAX_TOKENS=350
```

### 4. Install Frontend Dependencies

```bash
cd ../frontend
npm install
```

## Running the Application

### Start the Backend Server

```bash
cd backend
npm start
```

The API will run on `http://localhost:5001`

### Start the Frontend Development Server

```bash
cd frontend
npm start
```

The application will open in your browser at `http://localhost:3000`

## API Endpoints

- `GET /api/balance` - Get wallet balance
- `POST /api/add-funds` - Add funds
  - Body: `{ amount: number, description?: string }`
- `GET /api/payment-config` - Get strict payment configuration
  - Returns: `merchantId`, `merchantDisplayName`, `trustedQrFingerprint`, `maxPerTxnAmount`
- `POST /api/send-money` - Send money to trusted merchant with idempotency
  - Body: `{ amount, merchantId, idempotencyKey, authMethod?, description? }`
- `GET /api/transactions` - Get all transactions
- `POST /api/perception/analyze` - MiniCPM compatibility/fallback perception endpoint
  - Body: `{ mode: "scene"|"read"|"document", prompt?, ocrText?, imageBase64? }`

### LM Studio Wiring (MiniCPM)

The iOS app now prefers on-device MiniCPM execution. This backend route remains available as a fallback/debug path when the device does not have a working local model runtime.

1. In LM Studio, start Local Server (OpenAI-compatible).
2. Load a MiniCPM vision model (for example MiniCPM-V-4 GGUF).
3. Set backend env:
   - `MINICPM_API_URL=http://127.0.0.1:1234/v1/chat/completions`
   - `MINICPM_PROVIDER=lmstudio`
   - `MINICPM_MODEL=<your-lmstudio-model-id>`
4. Restart backend. When the device falls back to `/api/perception/analyze`, the backend will map requests to LM Studio chat format automatically.

## Project Structure

```
voice-vision/
├── backend/
│   ├── models/
│   ├── routes/
│   ├── services/
│   ├── server.js
│   └── package.json
├── frontend/
│   ├── src/
│   └── package.json
└── digital-wallet/README.md
```

## Usage

1. Open the application in your browser
2. Your current wallet balance will be displayed
3. Click "Add Funds" to deposit money
4. Click "Send Money" to transfer funds to another user
5. View your transaction history at the bottom of the page

## Telegram Notifications (Optional)

To enable Telegram notifications for transactions:

1. Create a bot via [@BotFather](https://t.me/BotFather) on Telegram
2. Copy your bot token
3. Get your chat ID by messaging [@userinfobot](https://t.me/userinfobot)
4. Add both to your `.env` file:
   ```
   TELEGRAM_BOT_TOKEN=your_bot_token
   TELEGRAM_CHAT_ID=your_chat_id
   ```

## iOS App Integration

This backend integrates with the **Blind Navigation** iOS app to provide QR code-based payment functionality for accessibility.

### How It Works

The Blind Navigation app allows visually impaired users to:
1. Scan QR codes using the iOS camera
2. Enter payment amounts via voice-guided interface
3. Verify payments using Face ID/Touch ID
4. Send money through the Digital Wallet backend

### Configuration for iOS

When testing with the iOS app, ensure:

1. **Backend is accessible**: Your iOS device must be able to reach the backend
   - Simulator: Uses `localhost` automatically
   - Physical Device: Update the IP in `blind-navigation/blind-navigation/BackendConfig.swift` to your Mac's LAN IP

2. **CORS is enabled**: The backend includes CORS support for cross-origin requests

3. **Port Configuration**: Default port is `5001` (configurable via `.env`)

### API Used by iOS App

The iOS app uses these endpoints:
- `GET /api/balance` - Check current balance
- `GET /api/payment-config` - Load trusted merchant config + QR fingerprint
- `POST /api/send-money` - Send money (strict merchant + idempotency)
- `POST /api/perception/analyze` - MiniCPM fallback scene/read/document analysis

For more details, see the [Blind Navigation README](../blind-navigation/README.md)

## License

This project is open source and available for educational purposes.
