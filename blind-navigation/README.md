# Blind Navigation

An iOS accessibility application designed to assist visually impaired users through advanced computer vision, machine learning, and augmented reality technologies.

## Features

### Core Functionality

- **Real-time Object Detection**: Uses AI to identify and announce objects in the user's environment
- **Text Recognition**: Extracts and reads text from images using OCR
- **MiniCPM Understanding Layer**: Scene explanation and document parsing via backend proxy
- **Currency Recognition**: Specifically designed to recognize and identify Indian currency (Rupees)
- **QR Code Scanning**: Scan and read QR codes for various purposes
- **Voice Announcements**: Provides audio feedback for all detected objects and information
- **AR Navigation**: Augmented reality overlay for enhanced spatial awareness

### Accessibility Features

- **Voice Feedback**: Text-to-speech announcements of detected objects
- **Obstacle Detection**: Warns users about potential hazards
- **Frame History Tracking**: Maintains context for object persistence
- **Object Cooldown System**: Prevents spam from repeated detections
- **Camera-based Assistance**: Real-time visual assistance through the device camera

## Tech Stack

- **Language**: Swift / SwiftUI
- **Platform**: iOS 17.0+
- **Frameworks**:
  - ARKit - Augmented Reality capabilities
  - Core ML - Machine learning model integration
  - AVFoundation - Camera access and media handling
  - Vision - Image analysis and text recognition
  - LocalAuthentication - Biometric security (Face ID / Touch ID)

### Machine Learning Models

- **YOLO11n**: Advanced object detection model (via Core ML)
- **IndianCurrency.mlmodel**: Custom-trained model for Indian currency recognition

## Requirements

- **iOS Version**: iOS 17.0 or later
- **Device**: iPhone with ARKit support (iPhone 6s and later)
- **Xcode**: Latest version for development
- **Camera**: Access to device camera
- **Microphone**: For voice feedback (optional)

## Installation

### Development Setup

1. **Clone the Repository**

```bash
git clone <repository-url>
cd blind-navigation
```

2. **Open in Xcode**

```bash
open blind-navigation.xcodeproj
```

3. **Configure Signing**

   - Select your development team in project settings
   - Ensure proper provisioning profiles

4. **Build and Run**

   - Select a simulator or connected device
   - Press Cmd+R to build and run

### ML Models

The project includes the following ML models:
- `IndianCurrency.mlmodel` - Currency detection
- `yolo11n.mlpackage` - Object detection

These models are included in the project and will be compiled automatically during the build process.

## Project Structure

```
blind-navigation/
├── blind-navigation/
│   ├── Views/
│   │   ├── ContentView.swift       # Main view
│   │   └── ObjectDetectionView.swift  # AR/ML view
│   ├── ViewModels/
│   │   └── ObjectDetectionViewModel.swift
│   ├── Models/
│   │   └── ML Models
│   ├── Assets.xcassets/
│   └── Info.plist
├── blind-navigation.xcodeproj/
└── README.md
```

## Usage

1. **Launch the App**: Open Blind Navigation on your iOS device
2. **Grant Permissions**: Allow camera access when prompted
3. **Point Camera**: Aim your device at objects or text you want to identify
4. **Listen for Feedback**: The app will announce what it detects

## Mode Switching

The app features three different modes controlled by touch gestures:

### Default Mode (Object Detection)
- **Features Active**: Object detection, text recognition, obstacle detection
- **Voice Feedback**: All detected objects and text are announced
- **Flashlight**: Off
- **MiniCPM Mode Selector**: `Scene`, `Read`, and `Doc` buttons in the top-right overlay

### Currency Recognition Mode
- **Activation**: Double-tap anywhere on the screen
- **Features Active**: Only Indian currency recognition
- **Flashlight**: Automatically turns on for better visibility
- **Disabled**: Object detection, OCR, and QR scanning
- **Deactivation**: Double-tap again to return to default mode
- **Use Case**: Identify Indian Rupee notes in low-light conditions

### QR Payment Mode
- **Activation**: Long-press (hold) anywhere on the screen
- **Features Active**: Only QR code scanning for payments
- **Flashlight**: Automatically turns on
- **Disabled**: Object detection, OCR, and currency recognition
- **Deactivation**: Long-press again to return to default mode
- **Integration**: Works with Digital Wallet backend for peer-to-peer payments

## Digital Wallet Integration

The Blind Navigation app integrates with the **Digital Wallet** system to enable QR code-based payments:

### Payment Flow

1. **Activate QR Payment Mode**: Long-press the screen
2. **Scan Trusted QR Code**: Point camera at the configured merchant QR
3. **Enter Amount**: When QR is detected, voice prompt asks for amount
4. **Review Step**: Confirm merchant + amount on dedicated review dialog
5. **Verify with Face ID**: Biometric authentication required for security
6. **Send Money**: App sends idempotent payment request to backend

### Configuration

The app fetches trusted payment config from backend (`GET /api/payment-config`):
- `merchantId`
- `merchantDisplayName`
- `trustedQrFingerprint`
- `maxPerTxnAmount`

Backend API base URL:
  - Simulator: `http://localhost:5001/api`
  - Device: `http://192.168.29.234:5001/api` (update with your Mac's LAN IP)

### Security Features

- **Face ID/Touch ID Required**: All payments require biometric verification
- **Two-Step Confirmation**: Explicit amount review before biometric auth
- **Trusted QR Check**: QR fingerprint must match backend configuration
- **Per-Transaction Limit**: Enforced client and server-side
- **Idempotency Key**: Prevents duplicate sends on retries
- **Voice Confirmation**: All actions are announced for accessibility

### Backend Requirements

To enable QR payments:
1. Run the Digital Wallet backend (see [Digital Wallet README](../digital-wallet/README.md))
2. Ensure your iOS device can reach the backend (same network or update IP in `BackendConfig.swift`)
3. Backend must be running on port 5001 (or update the port in config)

### Customization

To customize payment behavior:
1. Update backend env vars (`PAYMENT_MERCHANT_ID`, `PAYMENT_MERCHANT_NAME`, `PAYMENT_RECIPIENT_PHONE`, `PAYMENT_TRUSTED_QR_RAW`, `PAYMENT_MAX_PER_TXN`)
2. Update backend URL in `BackendConfig.swift` if needed

## Troubleshooting

### Common Issues

**Black Screen**
- Ensure camera permissions are granted
- Check ARKit compatibility with your device
- Try restarting the app

**No Voice Feedback**
- Verify device volume is not muted
- Check microphone permissions in Settings

**ML Model Errors**
- Ensure ML models are included in the project target
- Clean build folder (Cmd+Shift+K) and rebuild

## Permissions Required

The app requires the following permissions:
- **Camera**: For real-time object detection and AR features
- **Microphone**: For voice feedback (optional)

## Future Enhancements

- Navigation directions with turn-by-turn voice guidance
- Indoor mapping and localization
- Integration with accessibility services
- Support for more currencies
- Offline mode for basic features

## Contributing

Contributions are welcome! Please feel free to submit pull requests or open issues for bugs and feature requests.

## License

This project is open source and available for educational and accessibility purposes.

## Acknowledgments

- Built with Apple's ARKit and Core ML frameworks
- YOLO11n model for object detection
- Designed to improve accessibility for visually impaired users
