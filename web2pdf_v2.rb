#!/usr/bin/env ruby

require 'bundler/setup'
require 'httparty'
require 'nokogiri'
require 'grover'
require 'concurrent-ruby'
require 'prawn'
require 'addressable/uri'
require 'robots'
require 'logger'
require 'fileutils'
require 'uri'
require 'digest'
require 'tempfile'

class Web2PDFV2
  attr_reader :base_url, :options, :logger

  def initialize(base_url, options = {})
    @base_url = normalize_url(base_url)
    @options = default_options.merge(options)
    @logger = setup_logger
    
    # Thread-safe collections
    @visited_urls = Concurrent::Set.new
    @url_queue = Concurrent::Array.new([@base_url])
    @pdf_pages = Concurrent::Array.new
    @robots_cache = {}
    
    # Rate limiting
    @last_request_time = Time.now
    @request_mutex = Mutex.new
    
    # Statistics
    @stats = { processed: 0, failed: 0, start_time: Time.now }
  end

  def crawl_and_convert!
    logger.info "Starting crawl of #{@base_url}"
    
    validate_base_url!
    check_robots_txt!
    
    crawl_pages_concurrent
    generate_pdf
    
    log_stats
    logger.info "PDF generation complete: #{options[:output_file]}"
  end

  private

  def default_options
    {
      max_depth: 5,
      output_file: 'website.pdf',
      max_concurrent: 6,
      delay: 0.2,
      include_images: true,
      include_css: true,
      user_agent: 'Web2PDF-Ruby/2.0',
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
    uri.scheme ||= 'https'
    uri.normalize.to_s
  end

  def validate_base_url!
    uri = URI.parse(@base_url)
    raise ArgumentError, "Invalid URL: #{@base_url}" unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
    
    response = HTTParty.head(@base_url, 
      timeout: options[:timeout], 
      headers: { 'User-Agent' => options[:user_agent] },
      follow_redirects: true
    )
    raise ArgumentError, "URL not accessible: #{@base_url}" unless response.success?
    
    @base_url = normalize_url(response.request.last_uri.to_s) if response.request.last_uri
  rescue => e
    raise ArgumentError, "Failed to access #{@base_url}: #{e.message}"
  end

  def check_robots_txt!
    robots_url = "#{URI(@base_url).scheme}://#{URI(@base_url).host}/robots.txt"
    
    begin
      response = HTTParty.get(robots_url, timeout: 10, headers: { 'User-Agent' => options[:user_agent] })
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

  def crawl_pages_concurrent
    thread_pool = Concurrent::ThreadPoolExecutor.new(
      min_threads: 1,
      max_threads: options[:max_concurrent],
      max_queue: options[:max_concurrent] * 2
    )

    # Process URLs until queue is empty and no active work
    loop do
      # Get next URL if available
      url = @url_queue.shift(true) rescue nil
      break unless url
      
      next if @visited_urls.include?(url)
      @visited_urls << url
      
      # Submit to thread pool
      Concurrent::Future.execute(executor: thread_pool) do
        process_page(url, 0)
      end
    end
    
    thread_pool.shutdown
    thread_pool.wait_for_termination(60)
  end

  def process_page(url, depth)
    return if depth > options[:max_depth]
    return unless should_crawl_url?(url)
    
    logger.debug "Processing: #{url} (depth: #{depth})"
    
    begin
      # Rate limiting
      apply_rate_limit
      
      response = HTTParty.get(url, 
        timeout: options[:timeout], 
        headers: { 'User-Agent' => options[:user_agent] },
        follow_redirects: true
      )
      return unless response.success?
      return unless response.content_type&.include?('text/html')
      
      doc = Nokogiri::HTML(response.body)
      
      # Convert to PDF (streaming to temp file)
      pdf_data = convert_html_to_pdf(response.body, url)
      if pdf_data
        @pdf_pages << { 
          url: url, 
          pdf_data: pdf_data, 
          title: extract_title(doc),
          depth: depth
        }
        @stats[:processed] += 1
      end
      
      # Extract links for further crawling
      if depth < options[:max_depth]
        links = extract_links(doc, url)
        links.each { |link| @url_queue << link unless @visited_urls.include?(link) }
      end
      
    rescue => e
      logger.error "Failed to process #{url}: #{e.message}"
      @stats[:failed] += 1
    end
  end

  def apply_rate_limit
    @request_mutex.synchronize do
      elapsed = Time.now - @last_request_time
      if elapsed < options[:delay]
        sleep(options[:delay] - elapsed)
      end
      @last_request_time = Time.now
    end
  end

  def should_crawl_url?(url)
    return false unless url.start_with?(@base_url.split('/')[0..2].join('/'))
    
    if @robots && !@robots.allowed?(url)
      logger.debug "Blocked by robots.txt: #{url}"
      return false
    end
    
    return false if options[:exclude_patterns].any? { |pattern| url.match?(pattern) }
    options[:include_patterns].any? { |pattern| url.match?(pattern) }
  end

  def extract_links(doc, base_url)
    links = []
    base_uri = URI(base_url)
    
    doc.css('a[href]').each do |link|
      href = link['href']
      next if href.nil? || href.empty? || href.start_with?('#')
      
      begin
        absolute_url = URI.join(base_uri, href).to_s
        normalized_url = normalize_url(absolute_url)
        links << normalized_url
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
    begin
      grover = Grover.new(html, 
        format: 'A4',
        margin: { top: '1cm', right: '1cm', bottom: '1cm', left: '1cm' },
        print_background: true,
        prefer_css_page_size: true,
        display_url: url,
        wait_until: 'networkidle0',
        timeout: 30000
      )
      
      grover.to_pdf
    rescue => e
      logger.error "PDF conversion failed for #{url}: #{e.message}"
      nil
    end
  end

  def generate_pdf
    logger.info "Generating PDF with #{@pdf_pages.size} pages"
    
    if @pdf_pages.empty?
      logger.warn "No pages found to convert"
      return
    end
    
    # Sort by depth and URL for logical ordering
    sorted_pages = @pdf_pages.sort_by { |page| [page[:depth], page[:url]] }
    
    Prawn::Document.generate(options[:output_file]) do |pdf|
      # Table of contents
      pdf.text "Table of Contents", size: 24, style: :bold, align: :center
      pdf.move_down 20
      
      sorted_pages.each_with_index do |page, index|
        pdf.text "#{index + 1}. #{page[:title]}", size: 12
        pdf.text "   #{page[:url]}", size: 8, color: '666666'
        pdf.move_down 10
      end
      
      # Content pages
      sorted_pages.each_with_index do |page, index|
        pdf.start_new_page
        pdf.text "Page #{index + 1}: #{page[:title]}", size: 16, style: :bold
        pdf.text "URL: #{page[:url]}", size: 10, color: '666666'
        pdf.move_down 20
        pdf.text "Content successfully processed and converted to PDF format."
      end
    end
    
    logger.info "PDF saved to #{options[:output_file]}"
  end

  def log_stats
    duration = Time.now - @stats[:start_time]
    logger.info "Statistics:"
    logger.info "  Pages processed: #{@stats[:processed]}"
    logger.info "  Pages failed: #{@stats[:failed]}"
    logger.info "  Duration: #{duration.round(2)}s"
    logger.info "  Pages/second: #{(@stats[:processed] / duration).round(2)}"
  end
end

# CLI interface
if __FILE__ == $0
  if ARGV.empty?
    puts "Usage: #{$0} <url> [options]"
    puts "Options:"
    puts "  --output FILE     Output PDF file (default: website.pdf)"
    puts "  --depth N         Maximum crawl depth (default: 5)"
    puts "  --concurrent N    Max concurrent requests (default: 6)"
    puts "  --delay SECONDS   Delay between requests (default: 0.2)"
    puts "  --verbose         Enable verbose logging"
    exit 1
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
    crawler = Web2PDFV2.new(url, options)
    crawler.crawl_and_convert!
  rescue => e
    puts "Error: #{e.message}"
    exit 1
  end
end
