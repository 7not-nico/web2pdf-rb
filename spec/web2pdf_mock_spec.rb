require 'bundler/setup'
require 'rspec'
require 'webmock/rspec'
require_relative '../web2pdf'

# Disable external HTTP requests
WebMock.disable_net_connect!(allow_localhost: true)

describe Web2PDF do
  let(:base_url) { 'https://example.com' }
  let(:options) { { max_depth: 1, output_file: 'test.pdf', verbose: false } }
  let(:crawler) { Web2PDF.new(base_url, options) }

  before(:each) do
    # Mock HTTP requests
    stub_request(:head, base_url)
      .to_return(status: 200, headers: { 'Content-Type' => 'text/html' })
    
    stub_request(:get, "#{base_url}/robots.txt")
      .to_return(status: 404)
    
    stub_request(:get, base_url)
      .to_return(
        status: 200,
        headers: { 'Content-Type' => 'text/html' },
        body: '<html><head><title>Test Page</title></head><body><a href="/page1">Page 1</a></body></html>'
      )
    
    stub_request(:get, "#{base_url}/page1")
      .to_return(
        status: 200,
        headers: { 'Content-Type' => 'text/html' },
        body: '<html><head><title>Page 1</title></head><body></body></html>'
      )
  end

  describe '#initialize' do
    it 'normalizes base URL' do
      crawler = Web2PDF.new('example.com')
      expect(crawler.base_url).to eq('http://example.com')
    end

    it 'merges default options with provided options' do
      custom_options = { max_depth: 5, output_file: 'custom.pdf' }
      crawler = Web2PDF.new(base_url, custom_options)
      
      expect(crawler.options[:max_depth]).to eq(5)
      expect(crawler.options[:output_file]).to eq('custom.pdf')
      expect(crawler.options[:delay]).to eq(0.5) # default value
    end
  end

  describe '#normalize_url' do
    it 'adds http scheme when missing' do
      url = crawler.send(:normalize_url, 'example.com')
      expect(url).to eq('http://example.com')
    end

    it 'preserves existing https scheme' do
      url = crawler.send(:normalize_url, 'https://example.com')
      expect(url).to eq('https://example.com')
    end
  end

  describe '#should_crawl_url?' do
    it 'allows URLs from same domain' do
      url = 'https://example.com/index.html'
      expect(crawler.send(:should_crawl_url?, url)).to be_truthy
    end

    it 'rejects URLs from different domains' do
      url = 'https://other.com/page'
      expect(crawler.send(:should_crawl_url?, url)).to be_falsy
    end

    it 'respects exclude patterns' do
      crawler.options[:exclude_patterns] = [/.pdf$/]
      expect(crawler.send(:should_crawl_url?, 'https://example.com/file.pdf')).to be_falsy
    end

    it 'respects include patterns' do
      crawler.options[:include_patterns] = [/.html$/]
      expect(crawler.send(:should_crawl_url?, 'https://example.com/page.html')).to be_truthy
      expect(crawler.send(:should_crawl_url?, 'https://example.com/image.jpg')).to be_falsy
    end
  end

  describe '#extract_links' do
    let(:html) do
      <<~HTML
        <html>
          <body>
            <a href="/page1">Page 1</a>
            <a href="https://other.com/external">External</a>
            <a href="page2.html">Page 2</a>
            <a href="">Empty</a>
          </body>
        </html>
      HTML
    end

    it 'extracts and normalizes valid links' do
      doc = Nokogiri::HTML(html)
      links = crawler.send(:extract_links, doc, base_url)
      
      expect(links).to include('https://example.com/page1')
      expect(links).to include('https://example.com/page2.html')
    end

    it 'handles invalid URLs gracefully' do
      html_with_invalid = '<a href="://invalid">Invalid</a>'
      doc = Nokogiri::HTML(html_with_invalid)
      
      expect { crawler.send(:extract_links, doc, base_url) }.not_to raise_error
    end
  end

  describe '#extract_title' do
    it 'extracts title from HTML' do
      html = '<html><head><title>Test Page</title></head><body></body></html>'
      doc = Nokogiri::HTML(html)
      title = crawler.send(:extract_title, doc)
      
      expect(title).to eq('Test Page')
    end

    it 'returns default title when none exists' do
      html = '<html><head></head><body></body></html>'
      doc = Nokogiri::HTML(html)
      title = crawler.send(:extract_title, doc)
      
      expect(title).to eq('Untitled Page')
    end
  end
end