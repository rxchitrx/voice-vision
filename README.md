# Voice Vision

A collection of innovative applications focused on accessibility and financial management.

## Overview

> Temporary branch note: `codex/temp-no-ocr-payments` keeps the Blind Navigation
> navigation and currency features active while intentionally disabling the
> user-facing OCR text reader and QR/online wallet payment flow.

Voice Vision is a multi-project repository containing two distinct applications:

1. **[Digital Wallet](./digital-wallet/)** - A full-stack web application for managing personal finances
2. **[Blind Navigation](./blind-navigation/)** - An iOS accessibility app using AR and ML to assist visually impaired users

## Projects

### Digital Wallet

A modern web-based financial application built with React, Node.js, Express, and MongoDB.

**Key Features:**
- Real-time balance tracking
- Send and receive money
- Transaction history
- Telegram notifications
- RESTful API for iOS app integration

**Tech Stack:** React, Node.js, Express, MongoDB

**Link:** [Digital Wallet README](./digital-wallet/README.md)

---

### Blind Navigation

An iOS accessibility application designed to assist visually impaired users through computer vision and augmented reality.

**Key Features:**
- Real-time object detection
- Indian currency recognition
- Voice announcements
- AR wall, doorway, and window detection

**Disabled on this temporary branch:**
- User-facing text recognition (OCR)
- QR code scanning with wallet integration
- Face ID payment verification

**Tech Stack:** SwiftUI, ARKit, Core ML, Vision

**Link:** [Blind Navigation README](./blind-navigation/README.md)

## Directory Structure

```
voice-vision/
├── digital-wallet/          # React web application
│   ├── frontend/           # React frontend
│   ├── backend/            # Express.js backend
│   └── README.md           # Digital Wallet documentation
├── blind-navigation/        # iOS application
│   ├── blind-navigation/   # Xcode project
│   └── README.md           # Blind Navigation documentation
└── README.md               # This file
```

## Getting Started

Each project is independent and can be run separately. Choose the project you're interested in and follow its specific README:

- For the Digital Wallet web app, see [digital-wallet/README.md](./digital-wallet/README.md)
- For the Blind Navigation iOS app, see [blind-navigation/README.md](./blind-navigation/README.md)

## Prerequisites

### Digital Wallet (Web)
- Node.js (v14+)
- MongoDB
- npm or yarn

### Blind Navigation (iOS)
- macOS
- Xcode (latest version)
- iOS 17.0+ device or simulator

## Development

Each project has its own development environment:

```bash
# Digital Wallet - Backend
cd digital-wallet/backend
npm install
npm start

# Digital Wallet - Frontend
cd digital-wallet/frontend
npm install
npm start

# Blind Navigation - Open in Xcode
cd blind-navigation
open blind-navigation.xcodeproj
```

## Purpose

This repository showcases two different types of applications:

1. **Financial Technology**: Modern web development for managing digital finances
2. **Accessibility Technology**: Mobile development using cutting-edge AR/ML for improving accessibility

## Integration Between Projects

The Digital Wallet backend and web app are still present in this repository, but this temporary branch disables the Blind Navigation app's QR payment integration.

### How It Works

On the main app variant, Blind Navigation can integrate with the Digital Wallet backend for QR payments. On `codex/temp-no-ocr-payments`, long-press QR payment mode, wallet API calls, and biometric payment authorization are intentionally unavailable.

### Setting Up the Integration

To use both web wallet apps together:

1. Start the Digital Wallet backend (`cd digital-wallet/backend && npm start`)
2. Run the Digital Wallet frontend (optional, for web access)

For detailed setup instructions, see the individual project READMEs.

## Contributing

Contributions are welcome! Please specify which project you're contributing to when submitting pull requests or issues.

## License

This repository contains open source projects available for educational and practical use. Each project may have its own licensing terms.

## Contact

For questions or feedback about specific projects, please refer to the individual project READMEs.
