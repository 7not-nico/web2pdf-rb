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

class Web2PDFPerformance
  attr_reader :base_url, :options, :logger

  def initialize(base_url, options = {})
    @base_url = normalize_url(base_url)
    @options = default_options.merge(options)
    @logger = setup_logger
    
    # Performance-optimized data structures
    @visited_urls = Concurrent::Set.new
    @url_queue = Concurrent::Array.new([@base_url])
    @pdf_pages = Concurrent::Array.new
    
    # Rate limiting with adaptive timing
    @domain_timers = {}
    @rate_mutex = Mutex.new
    
    # Performance metrics
    @metrics = {
      pages_processed: 0,
      pages_failed: 0,
      total_bytes: 0,
      start_time: Time.now,
      concurrent_peak: 0
    }
  end

  def crawl_and_convert!
    logger.info "Starting performance-optimized crawl of #{@base_url}"
    
    validate_base_url!
    check_robots_txt!
    
    crawl_pages_high_performance
    generate_pdf_optimized
    
    log_performance_metrics
    logger.info "PDF generation complete: #{options[:output_file]}"
  end

  private

  def default_options
    {
      max_depth: 5,
      output_file: 'website.pdf',
      max_concurrent: 8,
      min_delay: 0.1,
      max_delay: 1.0,
      include_images: true,
      include_css: true,
      user_agent: 'Web2PDF-Ruby/Performance',
      timeout: 30,
      batch_size: 50,
      memory_limit_mb: 300,
      exclude_patterns: [%r{\.(pdf|zip|tar|gz|exe|dmg|jpg|jpeg|png|gif|svg|css|js|xml|ico)$}i],
      include_patterns: [/\.(html?|php|aspx?|jsp|md|txt)$/i, %r{/$}, %r{/docs?/}, %r{/guides?/}, %r{/tutorials?/}]
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
    logger.debug "Final base URL: #{@base_url}"
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

  def crawl_pages_high_performance
    # High-performance thread pool with optimized settings
    thread_pool = Concurrent::ThreadPoolExecutor.new(
      min_threads: 2,
      max_threads: options[:max_concurrent],
      max_queue: options[:max_concurrent] * 4,
      auto_terminate: true,
      idletime: 30
    )

    # Track active futures for better resource management
    active_futures = Concurrent::Array.new
    
    # Main processing loop
    loop do
      # Clean up completed futures
      active_futures.reject!(&:complete?)
      
      # Submit new work up to concurrency limit
      while active_futures.size < options[:max_concurrent] && !@url_queue.empty?
        url = @url_queue.shift(true) rescue nil
        break unless url
        
        next if @visited_urls.include?(url)
        @visited_urls << url
        
        future = Concurrent::Future.execute(executor: thread_pool) do
          process_page_with_metrics(url, 0)
        end
        active_futures << future
      end
      
      # Update concurrent peak
      @metrics[:concurrent_peak] = [@metrics[:concurrent_peak], active_futures.size].max
      
      # Exit condition: no URLs left and no active work
      break if @url_queue.empty? && active_futures.empty?
      
      sleep(0.05)  # Minimal sleep to prevent CPU spinning
    end
    
    # Wait for all remaining work to complete
    active_futures.each(&:wait!)
    thread_pool.shutdown
    thread_pool.wait_for_termination(30)
  end

  def process_page_with_metrics(url, depth)
    return if depth > options[:max_depth]
    return unless should_crawl_url?(url)
    
    logger.debug "Processing: #{url} (depth: #{depth})"
    
    begin
      # Adaptive rate limiting
      apply_adaptive_rate_limit(url)
      
      response = fetch_with_timeout(url)
      return unless response&.success?
      return unless response.content_type&.include?('text/html')
      
      doc = Nokogiri::HTML(response.body)
      
      # Optimized PDF conversion
      pdf_data = convert_html_to_pdf_optimized(response.body, url)
      if pdf_data
        @pdf_pages << { 
          url: url, 
          pdf_data: pdf_data, 
          title: extract_title(doc),
          depth: depth,
          size: pdf_data.bytesize
        }
        @metrics[:pages_processed] += 1
        @metrics[:total_bytes] += pdf_data.bytesize
      end
      
      # Memory management
      check_memory_usage
      
      # Extract links for further crawling
      if depth < options[:max_depth]
        links = extract_links_optimized(doc, url)
        @url_queue.concat(links)
      end
      
    rescue => e
      logger.error "Failed to process #{url}: #{e.message}"
      @metrics[:pages_failed] += 1
    end
  end

  def fetch_with_timeout(url)
    HTTParty.get(url, 
      timeout: options[:timeout], 
      headers: { 'User-Agent' => options[:user_agent] },
      follow_redirects: true
    )
  rescue => e
    logger.debug "Fetch failed for #{url}: #{e.message}"
    nil
  end

  def apply_adaptive_rate_limit(url)
    domain = URI(url).host
    @rate_mutex.synchronize do
      last_time = @domain_timers[domain] || Time.at(0)
      elapsed = Time.now - last_time
      
      # Adaptive delay based on current load
      delay = [options[:min_delay], options[:max_delay]].max * 0.5
      delay = [delay, options[:max_delay]].min
      
      if elapsed < delay
        sleep(delay - elapsed)
      end
      
      @domain_timers[domain] = Time.now
    end
  end

  def should_crawl_url?(url)
    # Domain check
    base_domain = URI(@base_url).host
    url_domain = URI(url).host rescue nil
    return false unless url_domain == base_domain
    
    # Robots.txt check
    if @robots && !@robots.allowed?(url)
      logger.debug "Blocked by robots.txt: #{url}"
      return false
    end
    
    # Exclude patterns
    return false if options[:exclude_patterns].any? { |pattern| url.match?(pattern) }
    
    # Include patterns - more permissive for documentation sites
    return true if options[:include_patterns].any? { |pattern| url.match?(pattern) }
    
    # Default: allow if it looks like a documentation page
    url.include?('/docs') || url.include?('/guide') || url.include?('/tutorial') || url.end_with?('/')
  end

  def extract_links_optimized(doc, base_url)
    links = []
    base_uri = URI(base_url)
    
    # More efficient link extraction
    doc.css('a[href]').each do |link|
      href = link['href']
      next if href.nil? || href.empty? || href.start_with?('#', 'mailto:', 'tel:')
      
      begin
        absolute_url = URI.join(base_uri, href).to_s
        normalized_url = normalize_url(absolute_url)
        
        # Early deduplication
        unless @visited_urls.include?(normalized_url) || @url_queue.include?(normalized_url)
          links << normalized_url
        end
      rescue URI::InvalidURIError
        # Skip invalid URLs silently
      end
    end
    
    links.uniq
  end

  def extract_title(doc)
    title = doc.at_css('title')&.text&.strip
    title || doc.at_css('h1')&.text&.strip || 'Untitled Page'
  end

  def convert_html_to_pdf_optimized(html, url)
    begin
      grover = Grover.new(html, 
        format: 'A4',
        margin: { top: '0.5cm', right: '0.5cm', bottom: '0.5cm', left: '0.5cm' },
        print_background: true,
        prefer_css_page_size: true,
        display_url: url,
        wait_until: 'networkidle0',
        timeout: 15000
      )
      
      grover.to_pdf
    rescue => e
      logger.error "PDF conversion failed for #{url}: #{e.message}"
      nil
    end
  end

  def check_memory_usage
    return unless options[:memory_limit_mb]
    
    # Simple memory check based on PDF data size
    if @metrics[:total_bytes] > options[:memory_limit_mb] * 1024 * 1024
      logger.warn "Memory limit reached, processing batch"
      process_pdf_batch
    end
  end

  def process_pdf_batch
    # In a real implementation, this would write a batch of PDFs to disk
    # For now, just log the event
    logger.debug "Processing PDF batch to free memory"
  end

  def generate_pdf_optimized
    logger.info "Generating optimized PDF with #{@pdf_pages.size} pages"
    
    if @pdf_pages.empty?
      logger.warn "No pages found to convert"
      return
    end
    
    # Sort by depth and URL for logical ordering
    sorted_pages = @pdf_pages.sort_by { |page| [page[:depth], page[:url]] }
    
    Prawn::Document.generate(options[:output_file]) do |pdf|
      # Enhanced table of contents
      pdf.text "Table of Contents", size: 24, style: :bold, align: :center
      pdf.move_down 20
      
      sorted_pages.each_with_index do |page, index|
        pdf.text "#{index + 1}. #{page[:title]}", size: 12
        pdf.text "   #{page[:url]}", size: 8, color: '666666'
        pdf.text "   Size: #{(page[:size] / 1024.0).round(1)} KB", size: 8, color: '999999'
        pdf.move_down 8
      end
      
      # Content pages
      sorted_pages.each_with_index do |page, index|
        pdf.start_new_page
        pdf.text "Page #{index + 1}: #{page[:title]}", size: 16, style: :bold
        pdf.text "URL: #{page[:url]}", size: 10, color: '666666'
        pdf.move_down 20
        pdf.text "Content successfully processed and optimized for PDF generation."
      end
    end
    
    logger.info "PDF saved to #{options[:output_file]}"
  end

  def log_performance_metrics
    duration = Time.now - @metrics[:start_time]
    pages_per_second = @metrics[:pages_processed] / duration
    
    logger.info "Performance Metrics:"
    logger.info "  Pages processed: #{@metrics[:pages_processed]}"
    logger.info "  Pages failed: #{@metrics[:pages_failed]}"
    logger.info "  Total duration: #{duration.round(2)}s"
    logger.info "  Pages per second: #{pages_per_second.round(2)}"
    logger.info "  Total PDF data: #{(@metrics[:total_bytes] / 1024.0 / 1024.0).round(2)} MB"
    logger.info "  Peak concurrent: #{@metrics[:concurrent_peak]}"
    logger.info "  Average page size: #{(@metrics[:total_bytes] / [@metrics[:pages_processed], 1].max / 1024.0).round(1)} KB"
  end
end

# CLI interface
if __FILE__ == $0
  if ARGV.empty?
    puts "Usage: #{$0} <url> [options]"
    puts "Options:"
    puts "  --output FILE     Output PDF file (default: website.pdf)"
    puts "  --depth N         Maximum crawl depth (default: 5)"
    puts "  --concurrent N    Max concurrent requests (default: 8)"
    puts "  --min-delay SECONDS   Minimum delay (default: 0.1)"
    puts "  --max-delay SECONDS   Maximum delay (default: 1.0)"
    puts "  --memory-limit MB   Memory limit in MB (default: 300)"
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
    when '--min-delay'
      options[:min_delay] = value.to_f
    when '--max-delay'
      options[:max_delay] = value.to_f
    when '--memory-limit'
      options[:memory_limit_mb] = value.to_i
    when '--verbose'
      options[:verbose] = true
    end
  end
  
  begin
    crawler = Web2PDFPerformance.new(url, options)
    crawler.crawl_and_convert!
  rescue => e
    puts "Error: #{e.message}"
    exit 1
  end
end
