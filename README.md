# Web2PDF-Ruby

A powerful Ruby script that crawls websites and converts them to PDF documents with advanced features for comprehensive web archiving.

## Features

- **Intelligent Crawling**: Recursively discovers all pages and directories within specified depth
- **High-Quality PDF**: Uses headless Chrome for perfect rendering of modern web pages
- **Concurrent Processing**: Multi-threaded crawling for improved performance
- **Robots.txt Compliance**: Respects website crawling policies
- **Table of Contents**: Automatically generates navigation with page titles and URLs
- **Rate Limiting**: Configurable delays to avoid overwhelming servers
- **Smart Filtering**: Include/exclude patterns for targeted crawling
- **Error Handling**: Robust error recovery and logging
- **Cross-Platform**: Works on Linux, macOS, and Windows

## Installation

1. Clone or download this repository
2. Install dependencies:
   ```bash
   bundle install
   ```

## Usage

### Basic Usage
```bash
./web2pdf.rb https://example.com
```

### Advanced Usage
```bash
./web2pdf.rb https://example.com \
  --output my-website.pdf \
  --depth 5 \
  --concurrent 10 \
  --delay 1.0 \
  --verbose
```

### Options

- `--output FILE`: Output PDF filename (default: website.pdf)
- `--depth N`: Maximum crawl depth (default: 3)
- `--concurrent N`: Maximum concurrent requests (default: 5)
- `--delay SECONDS`: Delay between requests (default: 0.5)
- `--verbose`: Enable detailed logging

## Requirements

- Ruby 2.7 or higher
- Google Chrome/Chromium (for PDF generation)
- Bundler gem

## Dependencies

- `httparty`: HTTP requests
- `nokogiri`: HTML parsing
- `grover`: PDF generation via headless Chrome
- `concurrent-ruby`: Parallel processing
- `prawn`: PDF manipulation
- `pdf-merger`: PDF combining
- `addressable`: URL handling
- `robots`: Robots.txt parsing

## Examples

### Crawl a Documentation Site
```bash
./web2pdf.rb https://docs.ruby-lang.org --depth 2 --output ruby-docs.pdf
```

### Archive a Blog
```bash
./web2pdf.rb https://blog.example.com --depth 3 --concurrent 3 --delay 2.0
```

### Quick Single-Page PDF
```bash
./web2pdf.rb https://example.com/about --depth 1 --output about.pdf
```

## Architecture

The script consists of several key components:

1. **URL Discovery**: Extracts and normalizes links from HTML pages
2. **Crawling Engine**: Manages concurrent page processing with depth control
3. **PDF Generation**: Converts HTML to PDF using headless Chrome
4. **Document Assembly**: Merges pages with table of contents
5. **Rate Limiting**: Implements respectful crawling delays

## Performance Tips

- Increase `--concurrent` for faster crawling (but be respectful to servers)
- Use `--depth` to limit scope for large sites
- Adjust `--delay` based on server response times
- Monitor verbose output to identify bottlenecks

## Limitations

- Requires JavaScript-enabled sites to work optimally
- Very large sites may require significant memory
- Some sites may block automated crawling
- Dynamic content loaded after page load may not be captured

## License

MIT License - feel free to use and modify for your needs.