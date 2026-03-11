#!/bin/zsh
#
# patch-webrtc-headers.sh - Fix stasel/WebRTC macOS headers
#
# The stasel/WebRTC xcframework has three issues on macOS native:
# 1. macOS slice ships with only umbrella header (missing 92 other headers)
# 2. Headers use internal Google import paths (sdk/objc/base/*)
# 3. Umbrella header includes iOS-only headers (UIKit, AVAudioSession)
#
# This script copies headers from the Catalyst slice and patches them.
# Run after SPM package resolution or clean build.
#
# Usage:
#   ./Tools/patch-webrtc-headers.sh
#   ./Tools/patch-webrtc-headers.sh /path/to/build/dir
#

set -e

BUILD_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)/build}"
XCF_BASE="$BUILD_DIR/SourcePackages/artifacts/webrtc/WebRTC/WebRTC.xcframework"
MACOS_HEADERS="$XCF_BASE/macos-x86_64_arm64/WebRTC.framework/Versions/A/Headers"
MACOS_MODULES="$XCF_BASE/macos-x86_64_arm64/WebRTC.framework/Versions/A/Modules"
CATALYST_HEADERS="$XCF_BASE/ios-x86_64_arm64-maccatalyst/WebRTC.framework/Versions/A/Headers"

if [[ ! -d "$XCF_BASE" ]]; then
  echo "⚠️  WebRTC xcframework not found at $XCF_BASE — skipping patch"
  exit 0
fi

if [[ ! -d "$CATALYST_HEADERS" ]]; then
  echo "❌ Catalyst headers not found at $CATALYST_HEADERS"
  exit 1
fi

# Step 1: Copy all headers from Catalyst slice to macOS slice
echo "📋 Copying headers from Catalyst slice..."
BEFORE=$(ls "$MACOS_HEADERS"/*.h 2>/dev/null | wc -l | tr -d ' ')
cp "$CATALYST_HEADERS"/*.h "$MACOS_HEADERS/"
AFTER=$(ls "$MACOS_HEADERS"/*.h 2>/dev/null | wc -l | tr -d ' ')
echo "   Headers: $BEFORE → $AFTER"

# Step 2: Fix internal Google import paths (sdk/objc/base/*)
echo "🔧 Fixing import paths..."
sed -i '' 's|#import "sdk/objc/base/\(.*\)"|#import "\1"|g' "$MACOS_HEADERS"/*.h
REMAINING=$(grep -rc 'sdk/objc' "$MACOS_HEADERS"/*.h 2>/dev/null | grep -v ':0$' | wc -l | tr -d ' ')
echo "   Remaining sdk/objc references: $REMAINING"

# Step 3: Write minimal umbrella header (excludes iOS-only headers)
echo "📝 Writing macOS-compatible umbrella header..."
cat > "$MACOS_HEADERS/WebRTC.h" << 'UMBRELLA'
/*
 *  Copyright 2025 The WebRTC project authors. All Rights Reserved.
 *  Patched umbrella header for macOS native — data channels only.
 *  iOS-only headers (UIKit, AVAudioSession) are excluded.
 *  See: Tools/patch-webrtc-headers.sh
 */

// Foundation types
#import <WebRTC/RTCMacros.h>
#import <WebRTC/RTCLogging.h>
#import <WebRTC/RTCFieldTrials.h>
#import <WebRTC/RTCSSLAdapter.h>
#import <WebRTC/RTCTracing.h>
#import <WebRTC/RTCCallbackLogger.h>
#import <WebRTC/RTCFileLogger.h>
#import <WebRTC/RTCMetrics.h>
#import <WebRTC/RTCMetricsSampleInfo.h>

// Configuration
#import <WebRTC/RTCConfiguration.h>
#import <WebRTC/RTCCertificate.h>
#import <WebRTC/RTCCryptoOptions.h>
#import <WebRTC/RTCIceServer.h>
#import <WebRTC/RTCMediaConstraints.h>
#import <WebRTC/RTCPeerConnectionFactoryOptions.h>

// Peer connection
#import <WebRTC/RTCPeerConnection.h>
#import <WebRTC/RTCPeerConnectionFactory.h>
#import <WebRTC/RTCSessionDescription.h>
#import <WebRTC/RTCIceCandidate.h>
#import <WebRTC/RTCIceCandidateErrorEvent.h>
#import <WebRTC/RTCLegacyStatsReport.h>
#import <WebRTC/RTCStatisticsReport.h>

// Data channel
#import <WebRTC/RTCDataChannel.h>
#import <WebRTC/RTCDataChannelConfiguration.h>

// Media (needed by RTCPeerConnection API)
#import <WebRTC/RTCMediaSource.h>
#import <WebRTC/RTCMediaStream.h>
#import <WebRTC/RTCMediaStreamTrack.h>
#import <WebRTC/RTCAudioSource.h>
#import <WebRTC/RTCAudioTrack.h>
#import <WebRTC/RTCVideoSource.h>
#import <WebRTC/RTCVideoTrack.h>

// RTP (needed by RTCPeerConnection API)
#import <WebRTC/RTCRtpTransceiver.h>
#import <WebRTC/RTCRtpReceiver.h>
#import <WebRTC/RTCRtpSender.h>
#import <WebRTC/RTCRtpSource.h>
#import <WebRTC/RTCRtpParameters.h>
#import <WebRTC/RTCRtpEncodingParameters.h>
#import <WebRTC/RTCRtpCodecParameters.h>
#import <WebRTC/RTCRtcpParameters.h>
#import <WebRTC/RTCRtpHeaderExtension.h>
#import <WebRTC/RTCRtpCapabilities.h>
#import <WebRTC/RTCRtpCodecCapability.h>
#import <WebRTC/RTCRtpHeaderExtensionCapability.h>
#import <WebRTC/RTCDtmfSender.h>

// Video frame types (needed by RTCVideoSource/Track)
#import <WebRTC/RTCVideoFrame.h>
#import <WebRTC/RTCVideoFrameBuffer.h>
#import <WebRTC/RTCI420Buffer.h>
#import <WebRTC/RTCMutableI420Buffer.h>
#import <WebRTC/RTCMutableYUVPlanarBuffer.h>
#import <WebRTC/RTCYUVPlanarBuffer.h>
#import <WebRTC/RTCNativeI420Buffer.h>
#import <WebRTC/RTCNativeMutableI420Buffer.h>
#import <WebRTC/RTCCVPixelBuffer.h>
#import <WebRTC/RTCVideoCapturer.h>
#import <WebRTC/RTCVideoRenderer.h>
#import <WebRTC/RTCSSLCertificateVerifier.h>

// Codec info (may be needed by factory)
#import <WebRTC/RTCCodecSpecificInfo.h>
#import <WebRTC/RTCEncodedImage.h>
#import <WebRTC/RTCVideoCodecInfo.h>
#import <WebRTC/RTCVideoCodecConstants.h>
#import <WebRTC/RTCVideoDecoder.h>
#import <WebRTC/RTCVideoDecoderFactory.h>
#import <WebRTC/RTCVideoEncoder.h>
#import <WebRTC/RTCVideoEncoderFactory.h>
#import <WebRTC/RTCVideoEncoderQpThresholds.h>
#import <WebRTC/RTCVideoEncoderSettings.h>
#import <WebRTC/RTCDefaultVideoDecoderFactory.h>
#import <WebRTC/RTCDefaultVideoEncoderFactory.h>
#import <WebRTC/RTCCodecSpecificInfoH264.h>
#import <WebRTC/RTCH264ProfileLevelId.h>
#import <WebRTC/RTCVideoDecoderFactoryH264.h>
#import <WebRTC/RTCVideoDecoderH264.h>
#import <WebRTC/RTCVideoEncoderFactoryH264.h>
#import <WebRTC/RTCVideoEncoderH264.h>
#import <WebRTC/RTCVideoDecoderVP8.h>
#import <WebRTC/RTCVideoDecoderVP9.h>
#import <WebRTC/RTCVideoDecoderAV1.h>
#import <WebRTC/RTCVideoEncoderVP8.h>
#import <WebRTC/RTCVideoEncoderVP9.h>
#import <WebRTC/RTCVideoEncoderAV1.h>
UMBRELLA

# Step 4: Write modulemap with excluded iOS-only headers
echo "📝 Writing modulemap with header exclusions..."
cat > "$MACOS_MODULES/module.modulemap" << 'MODULEMAP'
framework module WebRTC {
  umbrella header "WebRTC.h"
  exclude header "RTCEAGLVideoView.h"
  exclude header "RTCCameraPreviewView.h"
  exclude header "RTCMTLVideoView.h"
  exclude header "RTCVideoViewShading.h"
  exclude header "UIDevice+RTCDevice.h"
  exclude header "RTCAudioSession.h"
  exclude header "RTCAudioSessionConfiguration.h"
  exclude header "RTCAudioDevice.h"
  exclude header "RTCCameraVideoCapturer.h"
  exclude header "RTCFileVideoCapturer.h"
  exclude header "RTCNetworkMonitor.h"
  exclude header "RTCDispatcher.h"

  export *
  module * { export * }
}
MODULEMAP

echo "✅ WebRTC macOS headers patched successfully"
