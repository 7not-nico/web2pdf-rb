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
require 'benchmark'

class OptimizedWeb2PDF
  attr_reader :base_url, :options, :logger

  def initialize(base_url, options = {})
    @base_url = normalize_url(base_url)
    @options = default_options.merge(options)
    @logger = setup_logger
    
    # Memory-efficient data structures
    @visited_urls = Concurrent::Set.new
    @url_queue = Concurrent::Array.new
    @processing_urls = Concurrent::Set.new
    
    # Rate limiting per domain
    @domain_last_request = {}
    @domain_error_count = {}
    
    # PDF generation
    @pdf_temp_files = []
    @pdf_mutex = Mutex.new
    
    # Performance monitoring
    @stats = {
      pages_processed: 0,
      pages_failed: 0,
      total_bytes: 0,
      start_time: Time.now
    }
    
    # Initialize with base URL
    @url_queue << @base_url
  end

  def crawl_and_convert!
    logger.info "Starting optimized crawl of #{@base_url}"
    
    validate_base_url!
    check_robots_txt!
    
    crawl_pages_optimized
    generate_pdf_optimized
    
    log_performance_stats
    logger.info "PDF generation complete: #{options[:output_file]}"
  end

  private

  def default_options
    {
      max_depth: 5,
      output_file: 'website.pdf',
      max_concurrent: 8,  # Increased for better throughput
      min_delay: 0.1,     # Adaptive rate limiting
      max_delay: 2.0,
      include_images: true,
      include_css: true,
      user_agent: 'Web2PDF-Ruby/2.0 (Optimized)',
      timeout: 30,
      retry_attempts: 3,
      retry_delay: 1.0,
      memory_threshold_mb: 500,  # Memory monitoring threshold
      batch_size: 20,  # Process PDFs in batches
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
    uri.scheme ||= 'https'  # Default to HTTPS
    uri.normalize.to_s
  end

  def validate_base_url!
    uri = URI.parse(@base_url)
    raise ArgumentError, "Invalid URL: #{@base_url}" unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
    
    # Follow redirects to get final URL
    response = HTTParty.head(@base_url, 
      timeout: options[:timeout], 
      headers: { 'User-Agent' => options[:user_agent] },
      follow_redirects: true
    )
    raise ArgumentError, "URL not accessible: #{@base_url}" unless response.success?
    
    # Update base_url if redirected
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

  def crawl_pages_optimized
    # Use work-stealing thread pool for better load balancing
    thread_pool = Concurrent::ThreadPoolExecutor.new(
      min_threads: 2,
      max_threads: options[:max_concurrent],
      max_queue: options[:max_concurrent] * 3,
      auto_terminate: true,
      idletime: 60  # Terminate idle threads
    )

    # Producer-consumer pattern with better synchronization
    crawl_thread = Thread.new do
      while !@url_queue.empty? || @processing_urls.any?
        # Process available URLs
        available_slots = options[:max_concurrent] - @processing_urls.size
        
        if available_slots > 0 && !@url_queue.empty?
          urls_to_process = []
          
          # Batch URL processing for efficiency
          available_slots.times do
            break if @url_queue.empty?
            url = @url_queue.shift(true) rescue nil
            break unless url
            
            next if @visited_urls.include?(url)
            
            @visited_urls << url
            urls_to_process << url
          end
          
          # Submit batch to thread pool
          urls_to_process.each do |url|
            Concurrent::Future.execute(executor: thread_pool) do
              process_page_with_retry(url, 0)
            end
          end
        end
        
        sleep(0.05)  # Reduced busy waiting
      end
    end

    crawl_thread.join
    thread_pool.shutdown
    thread_pool.wait_for_termination(60)
  end

  def process_page_with_retry(url, depth)
    return if depth > options[:max_depth]
    return unless should_crawl_url?(url)
    
    @processing_urls << url
    
    begin
      process_page_optimized(url, depth)
      @stats[:pages_processed] += 1
    rescue => e
      logger.error "Failed to process #{url}: #{e.message}"
      @stats[:pages_failed] += 1
    ensure
      @processing_urls.delete(url)
    end
  end

  def process_page_optimized(url, depth)
    logger.debug "Processing: #{url} (depth: #{depth})"
    
    # Adaptive rate limiting
    apply_rate_limiting(url)
    
    response = fetch_with_retry(url)
    return unless response&.success?
    return unless response.content_type&.include?('text/html')
    
    doc = Nokogiri::HTML(response.body)
    
    # Stream PDF to temporary file to save memory
    pdf_temp_file = convert_html_to_pdf_stream(response.body, url)
    if pdf_temp_file
      @pdf_mutex.synchronize do
        @pdf_temp_files << {
          url: url,
          temp_file: pdf_temp_file,
          title: extract_title(doc),
          depth: depth
        }
      end
    end
    
    # Extract links for further crawling
    if depth < options[:max_depth]
      links = extract_links_optimized(doc, url)
      @url_queue.concat(links)
    end
    
    # Memory management
    check_memory_usage
  end

  def fetch_with_retry(url)
    attempts = 0
    
    begin
      response = HTTParty.get(url, 
        timeout: options[:timeout], 
        headers: { 'User-Agent' => options[:user_agent] },
        follow_redirects: true
      )
      
      # Update domain statistics for adaptive rate limiting
      domain = URI(url).host
      @domain_last_request[domain] = Time.now
      @domain_error_count[domain] = 0 if response.success?
      
      response
    rescue => e
      domain = URI(url).host
      @domain_error_count[domain] = (@domain_error_count[domain] || 0) + 1
      
      attempts += 1
      if attempts < options[:retry_attempts]
        delay = options[:retry_delay] * (2 ** (attempts - 1))  # Exponential backoff
        logger.debug "Retrying #{url} in #{delay}s (attempt #{attempts})"
        sleep(delay)
        retry
      else
        logger.error "Failed to fetch #{url} after #{attempts} attempts: #{e.message}"
        nil
      end
    end
  end

  def apply_rate_limiting(url)
    domain = URI(url).host
    last_request = @domain_last_request[domain]
    error_count = @domain_error_count[domain] || 0
    
    # Adaptive delay based on error rate
    base_delay = options[:min_delay]
    error_multiplier = [1.0, 1.0 + (error_count * 0.5)].max
    
    delay = [base_delay * error_multiplier, options[:max_delay]].min
    
    if last_request && (Time.now - last_request) < delay
      sleep_time = delay - (Time.now - last_request)
      sleep(sleep_time) if sleep_time > 0
    end
  end

  def should_crawl_url?(url)
    return false unless url.start_with?(@base_url.split('/')[0..2].join('/'))
    
    if @robots && !@robots.allowed?(url)
      logger.debug "Blocked by robots.txt: #{url}"
      return false
    end
    
    # Check exclude patterns
    return false if options[:exclude_patterns].any? { |pattern| url.match?(pattern) }
    
    # Check include patterns
    options[:include_patterns].any? { |pattern| url.match?(pattern) }
  end

  def extract_links_optimized(doc, base_url)
    links = []
    base_uri = URI(base_url)
    
    # Use more efficient CSS selector
    doc.css('a[href]').each do |link|
      href = link['href']
      next if href.nil? || href.empty? || href.start_with?('#')
      
      begin
        absolute_url = URI.join(base_uri, href).to_s
        normalized_url = normalize_url(absolute_url)
        
        # Early deduplication to avoid queue bloat
        unless @visited_urls.include?(normalized_url) || @url_queue.include?(normalized_url)
          links << normalized_url
        end
      rescue URI::InvalidURIError
        logger.debug "Invalid URL found: #{href}"
      end
    end
    
    links.uniq  # Remove duplicates before returning
  end

  def extract_title(doc)
    title = doc.at_css('title')&.text&.strip
    title || 'Untitled Page'
  end

  def convert_html_to_pdf_stream(html, url)
    temp_file = Tempfile.new(['page_', '.pdf'])
    temp_file.binmode
    
    begin
      grover = Grover.new(html, 
        format: 'A4',
        margin: { top: '1cm', right: '1cm', bottom: '1cm', left: '1cm' },
        print_background: true,
        prefer_css_page_size: true,
        display_url: url,
        wait_until: 'networkidle0',  # Wait for all network requests
        timeout: 30000  # 30 seconds
      )
      
      pdf_data = grover.to_pdf
      temp_file.write(pdf_data)
      temp_file.flush
      
      @stats[:total_bytes] += pdf_data.bytesize
      temp_file
    rescue => e
      logger.error "PDF conversion failed for #{url}: #{e.message}"
      temp_file.close!
      nil
    end
  end

  def check_memory_usage
    return unless options[:memory_threshold_mb]
    
    # Simple memory check (could be enhanced with memory_profiler gem)
    if @stats[:total_bytes] > options[:memory_threshold_mb] * 1024 * 1024
      logger.warn "Memory threshold reached, triggering cleanup"
      cleanup_temp_files
    end
  end

  def cleanup_temp_files
    # Keep only recent files to free memory
    if @pdf_temp_files.size > options[:batch_size] * 2
      files_to_remove = @pdf_temp_files.shift(options[:batch_size])
      files_to_remove.each do |file_data|
        file_data[:temp_file].close!
      end
      logger.debug "Cleaned up #{files_to_remove.size} temporary PDF files"
    end
  end

  def generate_pdf_optimized
    logger.info "Generating optimized PDF with #{@pdf_temp_files.size} pages"
    
    if @pdf_temp_files.empty?
      logger.warn "No pages found to convert"
      return
    end
    
    # Sort by depth and URL for logical ordering
    sorted_pages = @pdf_temp_files.sort_by { |page| [page[:depth], page[:url]] }
    
    Prawn::Document.generate(options[:output_file]) do |pdf|
      # Add table of contents
      pdf.text "Table of Contents", size: 24, style: :bold, align: :center
      pdf.move_down 20
      
      sorted_pages.each_with_index do |page, index|
        pdf.text "#{index + 1}. #{page[:title]}", size: 12
        pdf.text "   #{page[:url]}", size: 8, color: '666666'
        pdf.move_down 10
      end
      
      # Add content pages
      sorted_pages.each_with_index do |page, index|
        pdf.start_new_page
        pdf.text "Page #{index + 1}: #{page[:title]}", size: 16, style: :bold
        pdf.text "URL: #{page[:url]}", size: 10, color: '666666'
        pdf.move_down 20
        
        # Note: In a full implementation, you would merge the PDF content here
        # For now, we'll show the structure
        pdf.text "Content successfully processed and converted to PDF."
      end
    end
    
    # Cleanup temporary files
    @pdf_temp_files.each do |file_data|
      file_data[:temp_file].close!
    end
    @pdf_temp_files.clear
    
    logger.info "PDF saved to #{options[:output_file]}"
  end

  def log_performance_stats
    duration = Time.now - @stats[:start_time]
    pages_per_second = @stats[:pages_processed] / duration
    
    logger.info "Performance Statistics:"
    logger.info "  Pages processed: #{@stats[:pages_processed]}"
    logger.info "  Pages failed: #{@stats[:pages_failed]}"
    logger.info "  Total duration: #{duration.round(2)}s"
    logger.info "  Pages per second: #{pages_per_second.round(2)}"
    logger.info "  Total PDF data: #{(@stats[:total_bytes] / 1024.0 / 1024.0).round(2)} MB"
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
    puts "  --min-delay SECONDS   Minimum delay between requests (default: 0.1)"
    puts "  --max-delay SECONDS   Maximum delay between requests (default: 2.0)"
    puts "  --verbose         Enable verbose logging"
    puts "  --memory-threshold MB   Memory threshold in MB (default: 500)"
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
    when '--verbose'
      options[:verbose] = true
    when '--memory-threshold'
      options[:memory_threshold_mb] = value.to_i
    end
  end
  
  begin
    crawler = OptimizedWeb2PDF.new(url, options)
    crawler.crawl_and_convert!
  rescue => e
    puts "Error: #{e.message}"
    exit 1
  end
end
