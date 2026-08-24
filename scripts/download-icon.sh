#!/bin/bash
# Download the official Signal desktop icon for Unraid template
curl -sL -o signal-icon.png \
  "https://raw.githubusercontent.com/signalapp/Signal-Desktop/main/images/signal-logo-desktop-linux.png"
echo "Downloaded: $(wc -c < signal-icon.png) bytes"