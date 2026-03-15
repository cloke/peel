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
# It patches BOTH the SourcePackages xcframework AND the DerivedData
# framework copy (which the Clang dependency scanner uses).
#
# Usage:
#   ./Tools/patch-webrtc-headers.sh
#   ./Tools/patch-webrtc-headers.sh /path/to/derived-data-root
#

set -e

# When called from Xcode build phase: $1 = ${BUILD_DIR}/../.. = DerivedData/.../Build
# When called manually: no args, use project build/ dir
SEARCH_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)/build}"

# --- Locate the xcframework (search up from SEARCH_ROOT if needed) ---
find_xcframework() {
  local dir="$1"
  # Search the given dir and up to 2 parents
  for _ in 1 2 3; do
    local candidate="$dir/SourcePackages/artifacts/webrtc/WebRTC/WebRTC.xcframework"
    if [[ -d "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

XCF_BASE=$(find_xcframework "$SEARCH_ROOT") || true
if [[ -z "$XCF_BASE" ]]; then
  # Also try the project build/ dir as fallback
  PROJECT_BUILD="$(cd "$(dirname "$0")/.." && pwd)/build"
  XCF_BASE=$(find_xcframework "$PROJECT_BUILD") || true
fi

if [[ -z "$XCF_BASE" ]]; then
  echo "⚠️  WebRTC xcframework not found — skipping patch"
  exit 0
fi

MACOS_HEADERS="$XCF_BASE/macos-x86_64_arm64/WebRTC.framework/Versions/A/Headers"
MACOS_MODULES="$XCF_BASE/macos-x86_64_arm64/WebRTC.framework/Versions/A/Modules"
CATALYST_HEADERS="$XCF_BASE/ios-x86_64_arm64-maccatalyst/WebRTC.framework/Versions/A/Headers"

if [[ ! -d "$CATALYST_HEADERS" ]]; then
  echo "❌ Catalyst headers not found at $CATALYST_HEADERS"
  exit 1
fi

# --- Helper: patch a single Headers+Modules directory pair ---
patch_headers() {
  local target_headers="$1"
  local target_modules="$2"
  local label="$3"

  if [[ ! -d "$target_headers" ]]; then
    return
  fi

  local before=$(ls "$target_headers"/*.h 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$before" -gt 10 ]]; then
    # Already patched
    return
  fi

  # Copy all headers from Catalyst slice
  cp "$CATALYST_HEADERS"/*.h "$target_headers/"

  # Fix internal Google import paths (sdk/objc/base/*)
  sed -i '' 's|#import "sdk/objc/base/\(.*\)"|#import "\1"|g' "$target_headers"/*.h

  # Write macOS-compatible umbrella header
  cat > "$target_headers/WebRTC.h" << 'UMBRELLA'
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

  # Write modulemap
  if [[ -d "$target_modules" ]]; then
    cat > "$target_modules/module.modulemap" << 'MODULEMAP'
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
  fi

  local after=$(ls "$target_headers"/*.h 2>/dev/null | wc -l | tr -d ' ')
  echo "📋 $label: 1 → $after headers"
}

# --- Patch 1: Source xcframework (SourcePackages) ---
echo "Patching source xcframework..."
patch_headers "$MACOS_HEADERS" "$MACOS_MODULES" "xcframework"

# --- Patch 2: DerivedData Build/Products/Debug copy ---
# Find the DerivedData root by searching up from SEARCH_ROOT for Build/Products
find_dd_framework() {
  local dir="$1"
  for _ in 1 2 3 4; do
    local candidate="$dir/Build/Products/Debug/WebRTC.framework/Versions/A/Headers"
    if [[ -d "$candidate" ]]; then
      echo "$dir/Build/Products/Debug/WebRTC.framework"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

DD_FRAMEWORK=$(find_dd_framework "$SEARCH_ROOT") || true
if [[ -n "$DD_FRAMEWORK" && -d "$DD_FRAMEWORK" ]]; then
  echo "Patching DerivedData framework copy..."
  patch_headers "$DD_FRAMEWORK/Versions/A/Headers" "$DD_FRAMEWORK/Versions/A/Modules" "DerivedData"
fi

echo "✅ WebRTC macOS headers patched successfully"
