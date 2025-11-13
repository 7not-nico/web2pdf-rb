#!/usr/bin/env ruby

require 'bundler/setup'
require 'httparty'
require 'nokogiri'
require 'grover'
require 'concurrent-ruby'
require 'prawn'
# require 'pdf/merger'
require 'addressable/uri'
require 'robots'
require 'logger'
require 'fileutils'
require 'uri'
require 'digest'

class Web2PDF
  attr_reader :base_url, :options, :logger

  def initialize(base_url, options = {})
    @base_url = normalize_url(base_url)
    @options = default_options.merge(options)
    @logger = setup_logger
    @visited_urls = Concurrent::Set.new
    @url_queue = Concurrent::Array.new([@base_url])
    @pdf_pages = Concurrent::Array.new
    @robots_cache = {}
  end

  def crawl_and_convert!
    logger.info "Starting crawl of #{@base_url}"
    
    validate_base_url!
    check_robots_txt!
    
    crawl_pages
    generate_pdf
    
    logger.info "PDF generation complete: #{options[:output_file]}"
  end

  private

  def default_options
    {
      max_depth: 5,
      output_file: 'website.pdf',
      max_concurrent: 5,
      delay: 0.5,
      include_images: true,
      include_css: true,
      user_agent: 'Web2PDF-Ruby/1.0',
      timeout: 30,
      exclude_patterns: [%r{\.(pdf|zip|tar|gz|exe|dmg|jpg|jpeg|png|gif|svg|css|js)$}i],
      include_patterns: [/\.(html?|php|aspx?|jsp)$/i, %r{/$}, %r{/docs/}]
    }
  end

  def setup_logger
    logger = Logger.new(STDOUT)
    logger.level = options[:verbose] ? Logger::DEBUG : Logger::INFO
    logger.formatter = proc { |severity, datetime, progname, msg| "[#{severity}] #{msg}\n" }
    logger
  end

  def normalize_url(url)
    uri = Addressable::URI.parse(url)
    if uri.scheme.nil?
      # Build URL with proper scheme format
      "http://#{url}"
    else
      uri.to_s
    end
  end

  def validate_base_url!
    uri = URI.parse(@base_url)
    raise ArgumentError, "Invalid URL: #{@base_url}" unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
    
    response = HTTParty.head(@base_url, timeout: options[:timeout], headers: { 'User-Agent' => options[:user_agent] })
    raise ArgumentError, "URL not accessible: #{@base_url}" unless response.success?
  rescue => e
    raise ArgumentError, "Failed to access #{@base_url}: #{e.message}"
  end

  def check_robots_txt!
    robots_url = "#{URI(@base_url).scheme}://#{URI(@base_url).host}/robots.txt"
    
    begin
      response = HTTParty.get(robots_url, { timeout: 10, headers: { 'User-Agent' => options[:user_agent] } })
      if response.success?
        @robots = Robots.new(@base_url, response.body)
        logger.info "Robots.txt found and parsed"
      else
        logger.info "No robots.txt found, proceeding with crawl"
        @robots = nil
      end
    rescue => e
      logger.warn "Failed to fetch robots.txt: #{e.message}"
      @robots = nil
    end
  end

  def crawl_pages
    thread_pool = Concurrent::ThreadPoolExecutor.new(
      min_threads: 1,
      max_threads: options[:max_concurrent],
      max_queue: options[:max_concurrent] * 2
    )

    futures = []
    
    while !@url_queue.empty? || futures.any?
      # Process completed futures
      futures.reject!(&:complete?)
      
      # Add new tasks up to concurrency limit
      while futures.size < options[:max_concurrent] && !@url_queue.empty?
        url = @url_queue.shift
        next if @visited_urls.include?(url)
        
        @visited_urls << url
        futures << Concurrent::Future.execute(executor: thread_pool) { process_page(url, 0) }
      end
      
      sleep(0.1) # Small delay to prevent busy waiting
    end
    
    thread_pool.shutdown
    thread_pool.wait_for_termination(30)
  end

  def process_page(url, depth)
    return if depth > options[:max_depth]
    return unless should_crawl_url?(url)
    
    logger.debug "Processing: #{url} (depth: #{depth})"
    
    begin
      response = HTTParty.get(url, timeout: options[:timeout], headers: { 'User-Agent' => options[:user_agent] })
      return unless response.success?
      return unless response.content_type&.include?('text/html')
      
      doc = Nokogiri::HTML(response.body)
      
      # Convert to PDF
      pdf_data = convert_html_to_pdf(response.body, url)
      @pdf_pages << { url: url, pdf_data: pdf_data, title: extract_title(doc) }
      
      # Extract links for further crawling
      if depth < options[:max_depth]
        links = extract_links(doc, url)
        links.each { |link| @url_queue << link }
      end
      
      sleep(options[:delay]) # Rate limiting
      
    rescue => e
      logger.error "Failed to process #{url}: #{e.message}"
    end
  end

  def should_crawl_url?(url)
    base_domain = "#{URI(@base_url).scheme}://#{URI(@base_url).host}"
    return false unless url.start_with?(base_domain)
    
    if @robots && !@robots.allowed?(url)
      logger.debug "Blocked by robots.txt: #{url}"
      return false
    end
    
    # Check exclude patterns
    return false if options[:exclude_patterns].any? { |pattern| url.match?(pattern) }
    
    # Check include patterns
    options[:include_patterns].any? { |pattern| url.match?(pattern) }
  end

  def extract_links(doc, base_url)
    links = []
    
    doc.css('a[href]').each do |link|
      href = link['href']
      next if href.nil? || href.empty?
      
      begin
        absolute_url = URI.join(base_url, href).to_s
        normalized_url = normalize_url(absolute_url)
        
        links << normalized_url unless @visited_urls.include?(normalized_url)
      rescue URI::InvalidURIError
        logger.debug "Invalid URL found: #{href}"
      end
    end
    
    links.uniq
  end

  def extract_title(doc)
    title = doc.at_css('title')&.text&.strip
    title || 'Untitled Page'
  end

  def convert_html_to_pdf(html, url)
    grover = Grover.new(html, 
      format: 'A4',
      margin: { top: '1cm', right: '1cm', bottom: '1cm', left: '1cm' },
      print_background: true,
      prefer_css_page_size: true,
      display_url: url
    )
    
    grover.to_pdf
  end

  def generate_pdf
    logger.info "Generating PDF with #{@pdf_pages.size} pages"
    
    if @pdf_pages.empty?
      logger.warn "No pages found to convert"
      return
    end
    
    # Create a single PDF with table of contents and first page
    Prawn::Document.generate(options[:output_file]) do |pdf|
      # Add table of contents
      pdf.text "Table of Contents", size: 24, style: :bold, align: :center
      pdf.move_down 20
      
      @pdf_pages.sort_by { |page| page[:url] }.each_with_index do |page, index|
        pdf.text "#{index + 1}. #{page[:title]}", size: 12
        pdf.text "   #{page[:url]}", size: 8, color: '666666'
        pdf.move_down 10
      end
      
      # Start new page for content
      pdf.start_new_page
      
      # Add first page content if available
      if @pdf_pages.any?
        first_page = @pdf_pages.first
        pdf.text "Content from: #{first_page[:title]}", size: 16, style: :bold
        pdf.text "URL: #{first_page[:url]}", size: 10, color: '666666'
        pdf.move_down 20
        
        # Note: In a full implementation, we would convert HTML content here
        # For now, we'll just show that the crawling worked
        pdf.text "Page successfully crawled and processed."
        pdf.text "Total pages discovered: #{@pdf_pages.size}"
      end
    end
    
    logger.info "PDF saved to #{options[:output_file]}"
  end

  def generate_table_of_contents
    Prawn::Document.generate do |pdf|
      pdf.text "Table of Contents", size: 24, style: :bold, align: :center
      pdf.move_down 20
      
      @pdf_pages.sort_by { |page| page[:url] }.each_with_index do |page, index|
        pdf.text "#{index + 1}. #{page[:title]}", size: 12
        pdf.text "   #{page[:url]}", size: 8, color: '666666'
        pdf.move_down 10
      end
    end.render
  end
end

# CLI interface
if __FILE__ == $0
  if ARGV.empty? || ARGV[0] == '--help' || ARGV[0] == '-h'
    puts "Usage: #{$0} <url> [options]"
    puts "Options:"
    puts "  --output FILE     Output PDF file (default: website.pdf)"
    puts "  --depth N         Maximum crawl depth (default: 3)"
    puts "  --concurrent N    Max concurrent requests (default: 5)"
    puts "  --delay SECONDS   Delay between requests (default: 0.5)"
    puts "  --verbose         Enable verbose logging"
    puts "  --help, -h        Show this help"
    exit 0
  end
  
  url = ARGV[0]
  options = {}
  
  ARGV[1..-1].each_slice(2) do |key, value|
    case key
    when '--output'
      options[:output_file] = value
    when '--depth'
      options[:max_depth] = value.to_i
    when '--concurrent'
      options[:max_concurrent] = value.to_i
    when '--delay'
      options[:delay] = value.to_f
    when '--verbose'
      options[:verbose] = true
    end
  end
  
  begin
    crawler = Web2PDF.new(url, options)
    crawler.crawl_and_convert!
  rescue => e
    puts "Error: #{e.message}"
    exit 1
  end
end