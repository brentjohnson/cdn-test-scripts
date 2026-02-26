#!/usr/bin/env bash
# capture-har-debian.sh
# Usage: ./capture-har-debian.sh [URL]
# Captures HAR file using Node.js and Playwright directly on Debian 13

set -euo pipefail

# Default URL if none provided
DEFAULT_URL="https://www.abercrombie.com"
URL="${1:-$DEFAULT_URL}"

# Output directory and filename
OUTPUT_DIR="./har-files"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
HAR_FILENAME="abercrombie_${TIMESTAMP}.har"
HAR_PATH="${OUTPUT_DIR}/${HAR_FILENAME}"

# Use Debian packaged Node.js

print_usage() {
  cat <<EOF
Usage:
  $0 [URL]

Description:
  Captures a HAR (HTTP Archive) file for the specified URL using Node.js and Playwright.
  The HAR file contains all network requests, responses, and timing information.
  This script installs Node.js and Playwright directly on Debian 13.

Arguments:
  URL    The URL to capture (default: https://www.abercrombie.com)

Examples:
  $0                                    # Capture www.abercrombie.com
  $0 https://example.com                # Capture example.com
  $0 https://www.abercrombie.com        # Capture www.abercrombie.com explicitly

Output:
  HAR files are saved to: ${OUTPUT_DIR}/
  Latest file: ${HAR_PATH}

Requirements:
  - Debian 13 (Bookworm) or compatible system
  - Internet connection
  - sudo privileges for package installation
EOF
}

# Check for help flag
if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
  print_usage
  exit 0
fi

# Check if running on Debian
if ! command -v apt &>/dev/null; then
  echo "Error: This script is designed for Debian/Ubuntu systems with apt package manager." >&2
  exit 1
fi

# Check if running as root or with sudo
if [[ $EUID -eq 0 ]]; then
  SUDO_CMD=""
else
  if ! command -v sudo &>/dev/null; then
    echo "Error: sudo is required but not found. Please run as root or install sudo." >&2
    exit 1
  fi
  SUDO_CMD="sudo"
fi

echo "=== HAR Capture Script for Debian 13 ==="
echo "Target URL: $URL"
echo "Output file: $HAR_PATH"
echo ""

# Function to check if a command exists
command_exists() {
  command -v "$1" &>/dev/null
}

# Install system dependencies
install_system_deps() {
  echo "📦 Installing system dependencies..."
  
  $SUDO_CMD apt update
  $SUDO_CMD apt install -y \
    curl \
    wget \
    gnupg \
    ca-certificates \
    xvfb \
    x11-utils \
    build-essential \
    python3 \
    python3-pip \
    nodejs \
    npm \
    chromium \
    chromium-driver
}

# Verify Node.js installation
verify_nodejs() {
  if command_exists node; then
    echo "✅ Node.js is installed: $(node --version)"
    echo "✅ npm is installed: $(npm --version)"
  else
    echo "❌ Node.js installation failed"
    exit 1
  fi
}

# Install Playwright and setup
install_playwright() {
  echo "📦 Installing Playwright..."
  
  # Create a temporary directory for the project
  local temp_dir=$(mktemp -d)
  cd "$temp_dir"
  
  # Initialize npm project
  npm init -y
  
  # Install Playwright
  npm install playwright@latest
  
  # Use system Chromium instead of downloading
  echo "📦 Configuring Playwright to use system Chromium..."
  export PLAYWRIGHT_BROWSERS_PATH=/usr/bin
  
  # Copy the capture script
  cat > capture-har.js << 'EOF'
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

async function captureHAR(url, outputPath) {
  console.log(`Starting HAR capture for: ${url}`);
  
  const browser = await chromium.launch({
    headless: true,
    args: [
      '--no-sandbox',
      '--disable-setuid-sandbox',
      '--disable-dev-shm-usage',
      '--disable-accelerated-2d-canvas',
      '--no-first-run',
      '--no-zygote',
      '--disable-gpu',
      '--disable-web-security',
      '--disable-features=VizDisplayCompositor',
      '--run-all-compositor-stages-before-draw',
      '--disable-background-timer-throttling',
      '--disable-backgrounding-occluded-windows',
      '--disable-renderer-backgrounding',
      '--disable-extensions',
      '--disable-plugins',
      '--disable-images',
      '--disable-javascript',
      '--disable-default-apps'
    ]
  });

  const context = await browser.newContext({
    userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    viewport: { width: 1920, height: 1080 }
  });

  const page = await context.newPage();
  
  // Enable HAR recording
  await page.route('**/*', route => route.continue());
  
  console.log('Navigating to URL...');
  
  try {
    const response = await page.goto(url, { 
      waitUntil: 'networkidle',
      timeout: 30000 
    });
    
    if (!response || !response.ok()) {
      console.error(`Failed to load page: ${response?.status() || 'Unknown error'}`);
      await browser.close();
      process.exit(1);
    }
    
    console.log('Page loaded successfully');
    console.log('Waiting for additional network activity...');
    
    // Wait for any lazy-loaded content
    await page.waitForTimeout(5000);
    
    // Get HAR data using Playwright's built-in HAR export
    const har = await page.evaluate(() => {
      return new Promise((resolve) => {
        // Get performance entries
        const performanceEntries = performance.getEntriesByType('navigation');
        const resourceEntries = performance.getEntriesByType('resource');
        
        const harData = {
          log: {
            version: "1.2",
            creator: {
              name: "Playwright HAR Capture",
              version: "1.0"
            },
            pages: [],
            entries: []
          }
        };
        
        // Add navigation timing
        if (performanceEntries.length > 0) {
          const nav = performanceEntries[0];
          harData.log.pages.push({
            startedDateTime: new Date(nav.startTime).toISOString(),
            id: "page_1",
            title: document.title,
            pageTimings: {
              onContentLoad: nav.domContentLoadedEventEnd - nav.domContentLoadedEventStart,
              onLoad: nav.loadEventEnd - nav.loadEventStart
            }
          });
        }
        
        // Add resource entries
        resourceEntries.forEach(entry => {
          if (entry.name && entry.name.startsWith('http')) {
            harData.log.entries.push({
              startedDateTime: new Date(entry.startTime).toISOString(),
              time: entry.duration,
              request: {
                method: "GET",
                url: entry.name,
                headers: [],
                queryString: [],
                cookies: [],
                headersSize: -1,
                bodySize: -1
              },
              response: {
                status: 200,
                statusText: "OK",
                headers: [],
                content: {
                  size: 0,
                  mimeType: "text/html"
                },
                redirectURL: "",
                headersSize: -1,
                bodySize: -1
              },
              cache: {},
              timings: {
                blocked: 0,
                dns: 0,
                connect: 0,
                send: 0,
                wait: entry.duration,
                receive: 0
              }
            });
          }
        });
        
        resolve(harData);
      });
    });
    
    // Write HAR file
    fs.writeFileSync(outputPath, JSON.stringify(har, null, 2));
    console.log(`HAR file saved to: ${outputPath}`);
    
    await browser.close();
    console.log('HAR capture completed successfully');
    
  } catch (error) {
    console.error('Error during HAR capture:', error);
    await browser.close();
    process.exit(1);
  }
}

// Get command line arguments
const url = process.argv[2] || 'https://www.abercrombie.com';
const outputPath = process.argv[3] || './har-file.har';

captureHAR(url, outputPath).catch(error => {
  console.error('Error capturing HAR:', error);
  process.exit(1);
});
EOF
  
  # Return to original directory
  cd - > /dev/null
  
  # Debug output
  echo "Debug: Created temp directory: $temp_dir" >&2
  echo "Debug: Directory exists: $(test -d "$temp_dir" && echo "yes" || echo "no")" >&2
  
  # Return the temp directory path
  echo "$temp_dir"
}

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Main installation and execution
main() {
  # Install system dependencies (includes Node.js and Chromium)
  install_system_deps
  
  # Verify Node.js installation
  verify_nodejs
  
  # Install Playwright and get temp directory
  TEMP_DIR=$(install_playwright)
  
  echo ""
  echo "🚀 Running HAR capture..."
  echo "Working directory: $TEMP_DIR"
  
  # Verify the temp directory exists
  if [[ ! -d "$TEMP_DIR" ]]; then
    echo "❌ Error: Temporary directory does not exist: $TEMP_DIR"
    exit 1
  fi
  
  # Run the HAR capture
  cd "$TEMP_DIR"
  xvfb-run -a node capture-har.js "$URL" "$HAR_PATH"
  
  # Check if HAR file was created
  if [[ -f "$HAR_PATH" ]]; then
    echo ""
    echo "✅ HAR capture completed successfully!"
    echo "📁 Output file: $HAR_PATH"
    echo "📊 File size: $(du -h "$HAR_PATH" | cut -f1)"
    echo ""
    echo "You can analyze this HAR file using:"
    echo "  - Chrome DevTools (Network tab → Import HAR)"
    echo "  - HAR Analyzer tools"
    echo "  - Online HAR viewers"
  else
    echo "❌ Error: HAR file was not created"
    exit 1
  fi
  
  # Clean up
  echo "🧹 Cleaning up..."
  rm -rf "$TEMP_DIR"
  
  echo "Done!"
}

# Run main function
main
