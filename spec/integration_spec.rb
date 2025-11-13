require 'bundler/setup'
require 'rspec'
require 'webmock/rspec'
require 'benchmark'

# Disable external HTTP requests
WebMock.disable_net_connect!(allow_localhost: true)

describe 'Web2PDF Integration Tests' do
  let(:base_url) { 'https://example.com' }
  let(:options) { { max_depth: 2, output_file: 'test.pdf', verbose: false } }
  
  before(:each) do
    # Mock common HTTP requests for all tests
    stub_request(:head, /example\.com/)
      .to_return(status: 200, headers: { 'Content-Type' => 'text/html' })
    
    stub_request(:get, /.*robots\.txt/)
      .to_return(status: 404)
    
    stub_request(:get, base_url)
      .to_return(
        status: 200,
        headers: { 'Content-Type' => 'text/html' },
        body: '<html><head><title>Home</title></head><body><a href="/page1">Page 1</a><a href="/page2">Page 2</a></body></html>'
      )
    
    stub_request(:get, "#{base_url}/page1")
      .to_return(
        status: 200,
        headers: { 'Content-Type' => 'text/html' },
        body: '<html><head><title>Page 1</title></head><body></body></html>'
      )
    
    stub_request(:get, "#{base_url}/page2")
      .to_return(
        status: 200,
        headers: { 'Content-Type' => 'text/html' },
        body: '<html><head><title>Page 2</title></head><body></body></html>'
      )
  end

  describe 'web2pdf.rb (Main Version)' do
    it 'initializes and normalizes URLs correctly' do
      require_relative '../web2pdf'
      crawler = Web2PDF.new(base_url, options)
      
      expect(crawler.base_url).to eq(base_url)
      expect(crawler.options[:max_depth]).to eq(2)
    end

    it 'validates URLs properly' do
      require_relative '../web2pdf'
      crawler = Web2PDF.new(base_url, options)
      
      expect(crawler.send(:should_crawl_url?, "#{base_url}/index.html")).to be_truthy
      expect(crawler.send(:should_crawl_url?, "https://other.com/page")).to be_falsy
    end
  end

  describe 'web2pdf_slim.rb (KISS Version)' do
    it 'initializes and normalizes URLs correctly' do
      require_relative '../web2pdf_slim'
      crawler = Web2PDF.new(base_url, options)
      
      expect(crawler.base_url).to eq(base_url)
      expect(crawler.options[:max_depth]).to eq(2)
    end

    it 'validates URLs properly' do
      require_relative '../web2pdf_slim'
      crawler = Web2PDF.new(base_url, options)
      
      expect(crawler.send(:should_crawl?, "#{base_url}/index.html")).to be_truthy
      expect(crawler.send(:should_crawl?, "https://other.com/page")).to be_falsy
    end
  end

  describe 'web2pdf_performance.rb (Optimized Version)' do
    it 'initializes and normalizes URLs correctly' do
      require_relative '../web2pdf_performance'
      crawler = Web2PDF.new(base_url, options)
      
      expect(crawler.base_url).to eq(base_url)
      expect(crawler.options[:max_depth]).to eq(2)
    end

    it 'validates URLs properly' do
      require_relative '../web2pdf_performance'
      crawler = Web2PDF.new(base_url, options)
      
      expect(crawler.send(:should_crawl?, "#{base_url}/index.html")).to be_truthy
      expect(crawler.send(:should_crawl?, "https://other.com/page")).to be_falsy
    end
  end

  describe 'CLI Interface' do
    it 'shows help for main version' do
      expect { system("ruby ../web2pdf.rb --help") }.not_to raise_error
    end

    it 'shows help for slim version' do
      expect { system("ruby ../web2pdf_slim.rb --help") }.not_to raise_error
    end

    it 'shows help for performance version' do
      expect { system("ruby ../web2pdf_performance.rb --help") }.not_to raise_error
    end
  end
end