#!/bin/bash

# Web2PDF-Ruby Installation and Setup Script

set -e

echo "🚀 Setting up Web2PDF-Ruby..."

# Check if Ruby is installed
if ! command -v ruby &> /dev/null; then
    echo "❌ Ruby is not installed. Please install Ruby 2.7 or higher."
    exit 1
fi

# Check Ruby version
ruby_version=$(ruby -e 'puts RUBY_VERSION')
required_version="2.7"

if [ "$(printf '%s\n' "$required_version" "$ruby_version" | sort -V | head -n1)" != "$required_version" ]; then
    echo "❌ Ruby version $ruby_version is too old. Please upgrade to Ruby $required_version or higher."
    exit 1
fi

echo "✅ Ruby version $ruby_version detected"

# Check if Bundler is installed
if ! command -v bundle &> /dev/null; then
    echo "📦 Installing Bundler..."
    gem install bundler
fi

# Install dependencies
echo "📦 Installing Ruby gems..."
bundle install

# Check if Chrome/Chromium is installed
if command -v google-chrome &> /dev/null; then
    echo "✅ Google Chrome detected"
elif command -v chromium-browser &> /dev/null; then
    echo "✅ Chromium detected"
elif command -v chromium &> /dev/null; then
    echo "✅ Chromium detected"
else
    echo "⚠️  Warning: No Chrome/Chromium installation found."
    echo "   Please install Google Chrome or Chromium for PDF generation."
    echo "   On Ubuntu/Debian: sudo apt-get install chromium-browser"
    echo "   On macOS: brew install --cask google-chrome"
fi

# Make scripts executable
chmod +x web2pdf.rb
chmod +x examples.rb

# Create output directory
mkdir -p output

echo ""
echo "🎉 Setup complete!"
echo ""
echo "Usage examples:"
echo "  ./web2pdf.rb https://example.com"
echo "  ./web2pdf.rb https://docs.ruby-lang.org --depth 2 --output ruby-docs.pdf"
echo "  ruby examples.rb"
echo ""
echo "Generated PDFs will be saved in the current directory."
echo ""