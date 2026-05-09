# Blind Navigation

An iOS accessibility application designed to assist visually impaired users through advanced computer vision, machine learning, and augmented reality technologies.

> Temporary branch note: `codex/temp-no-ocr-payments` intentionally disables
> user-facing OCR text reading and QR/online wallet payments. Navigation,
> obstacle/object detection, AR spatial detection, speech, and currency mode
> remain active.

## Features

### Core Functionality

- **Real-time Object Detection**: Uses AI to identify and announce objects in the user's environment
- **Currency Recognition**: Specifically designed to recognize and identify Indian currency (Rupees)
- **Voice Announcements**: Provides audio feedback for all detected objects and information
- **AR Navigation**: Augmented reality overlay for enhanced spatial awareness

Disabled on this temporary branch:
- User-facing text recognition/OCR reading
- QR code payment scanning
- Biometric payment authorization

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
3. **Point Camera**: Aim your device at objects or currency you want to identify
4. **Listen for Feedback**: The app will announce what it detects

## Mode Switching

The app features two active modes controlled by touch gestures:

### Default Mode (Object Detection)
- **Features Active**: Object detection, obstacle detection, AR wall/doorway/window detection
- **Voice Feedback**: Detected objects and obstacles are announced
- **Flashlight**: Off

### Currency Recognition Mode
- **Activation**: Double-tap anywhere on the screen
- **Features Active**: Only Indian currency recognition
- **Flashlight**: Automatically turns on for better visibility
- **Disabled**: Object detection while currency mode is active
- **Deactivation**: Double-tap again to return to default mode
- **Use Case**: Identify Indian Rupee notes in low-light conditions

Long-press QR payment mode is disabled on this temporary branch.

## Digital Wallet Integration

The Digital Wallet backend and web app remain in the repository, but this temporary iOS branch does not call the wallet API or expose QR payment UI.

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
