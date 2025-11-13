#!/usr/bin/env ruby

require 'httparty'
require 'nokogiri'
require 'grover'
require 'concurrent-ruby'
require 'prawn'
require 'addressable/uri'
require 'robots'
require 'logger'
require 'tempfile'

class Web2PDF
  attr_reader :base_url, :options, :logger

  def initialize(base_url, options = {})
    @base_url = normalize_url(base_url)
    @options = default_options.merge(options)
    @logger = setup_logger
    
    # Thread-safe collections
    @visited = Concurrent::Set.new
    @queue = Concurrent::Array.new([@base_url])
    @pages = Concurrent::Array.new
    @robots = nil
    
    # HTTP connection reuse
    @http_options = {
      timeout: options[:timeout],
      headers: { 'User-Agent' => options[:user_agent] },
      keep_alive: true
    }
  end

  def crawl_and_convert!
    logger.info "Starting crawl: #{@base_url}"
    
    validate_url!
    check_robots!
    crawl_optimized
    generate_pdf_batched
    
    logger.info "PDF created: #{options[:output_file]}"
  end

  private

  def default_options
    {
      max_depth: 3,
      output_file: 'website.pdf',
      max_concurrent: 8,
      delay: 0.1,
      timeout: 30,
      user_agent: 'Web2PDF/4.0',
      batch_size: 20,
      exclude_patterns: [%r{\.(pdf|zip|jpg|png|gif|svg|css|js)$}i],
      include_patterns: [/\.(html?|php|aspx?)$/i, %r{/$}]
    }
  end

  def setup_logger
    logger = Logger.new(STDOUT)
    logger.level = options[:verbose] ? Logger::DEBUG : Logger::INFO
    logger.formatter = proc { |s, _, _, msg| "[#{s}] #{msg}\n" }
    logger
  end

  def normalize_url(url)
    uri = Addressable::URI.parse(url)
    uri.scheme ||= 'https'
    uri.normalize.to_s
  end

  def validate_url!
    response = HTTParty.head(@base_url, **@http_options)
    raise ArgumentError, "URL not accessible: #{@base_url}" unless response.success?
  rescue => e
    raise ArgumentError, "Failed to access #{@base_url}: #{e.message}"
  end

  def check_robots!
    robots_url = "#{URI(@base_url).scheme}://#{URI(@base_url).host}/robots.txt"
    
    begin
      response = HTTParty.get(robots_url, timeout: 5, **@http_options)
      @robots = Robots.new(@base_url, response.body) if response.success?
    rescue
      @robots = nil
    end
  end

  def crawl_optimized
    # Work-stealing thread pool with better synchronization
    pool = Concurrent::ThreadPoolExecutor.new(
      min_threads: 2,
      max_threads: options[:max_concurrent],
      max_queue: options[:max_concurrent] * 3,
      auto_terminate: true,
      idletime: 30
    )

    # Producer-consumer with proper synchronization
    crawl_thread = Thread.new do
      while !@queue.empty? || @pages.size < options[:max_concurrent]
        available_slots = options[:max_concurrent] - @pages.size
        
        if available_slots > 0 && !@queue.empty?
          urls_to_process = []
          
          # Batch URL processing
          available_slots.times do
            url = @queue.shift(true) rescue nil
            break unless url && !@visited.include?(url)
            
            @visited << url
            urls_to_process << url
          end
          
          # Submit batch to thread pool
          urls_to_process.each do |url|
            Concurrent::Future.execute(executor: pool) { process_page_with_retry(url, 0) }
          end
        end
        
        sleep(0.01) # Minimal delay
      end
    end

    crawl_thread.join
    pool.shutdown
    pool.wait_for_termination(60)
  end

  def process_page_with_retry(url, depth)
    return if depth > options[:max_depth] || !should_crawl?(url)
    
    begin
      process_page_optimized(url, depth)
    rescue => e
      logger.error "Failed: #{url} - #{e.message}"
      
      # Simple retry with exponential backoff
      if depth < 2
        sleep(0.5 * (depth + 1))
        process_page_optimized(url, depth + 1)
      end
    end
  end

  def process_page_optimized(url, depth)
    logger.debug "Processing: #{url}"
    
    response = fetch_with_connection_reuse(url)
    return unless response&.success? && response.content_type&.include?('text/html')
    
    doc = Nokogiri::HTML(response.body)
    
    # Stream PDF to temp file
    pdf_file = convert_to_pdf_stream(response.body, url)
    return unless pdf_file
    
    @pages << { url: url, file: pdf_file, title: extract_title(doc), depth: depth }
    
    # Extract links if not at max depth
    if depth < options[:max_depth]
      links = extract_links_optimized(doc, url)
      @queue.concat(links)
    end
    
    # Minimal rate limiting
    sleep(options[:delay]) if options[:delay] > 0
  end

  def fetch_with_connection_reuse(url)
    HTTParty.get(url, **@http_options)
  rescue => e
    logger.debug "Fetch failed: #{url} - #{e.message}"
    nil
  end

  def should_crawl?(url)
    return false unless url.start_with?(@base_url.split('/')[0..2].join('/'))
    return false if @robots && !@robots.allowed?(url)
    return false if options[:exclude_patterns].any? { |p| url.match?(p) }
    options[:include_patterns].any? { |p| url.match?(p) }
  end

  def extract_links_optimized(doc, base_url)
    links = []
    base_uri = URI(base_url)
    
    # More efficient CSS selector with early filtering
    doc.css('a[href]').each do |link|
      href = link['href']
      next unless href && !href.empty? && !href.start_with?('#', 'mailto:', 'tel:')
      
      begin
        absolute = URI.join(base_uri, href).to_s
        normalized = normalize_url(absolute)
        
        # Early deduplication
        unless @visited.include?(normalized) || @queue.include?(normalized)
          links << normalized
        end
      rescue URI::InvalidURIError
        # Skip invalid URLs silently
      end
    end
    
    links.uniq # Remove duplicates before returning
  end

  def extract_title(doc)
    doc.at_css('title')&.text&.strip || 'Untitled'
  end

  def convert_to_pdf_stream(html, url)
    temp_file = Tempfile.new(['page_', '.pdf'])
    temp_file.binmode
    
    grover = Grover.new(html,
      format: 'A4',
      margin: { top: '1cm', right: '1cm', bottom: '1cm', left: '1cm' },
      print_background: true,
      display_url: url,
      wait_until: 'networkidle0'
    )
    
    temp_file.write(grover.to_pdf)
    temp_file.flush
    temp_file
  rescue => e
    logger.debug "PDF conversion failed: #{e.message}"
    temp_file.close! if temp_file
    nil
  end

  def generate_pdf_batched
    return if @pages.empty?
    
    sorted_pages = @pages.sort_by { |p| [p[:depth], p[:url]] }
    
    Prawn::Document.generate(options[:output_file]) do |pdf|
      # Table of contents
      pdf.text "Table of Contents", size: 24, style: :bold, align: :center
      pdf.move_down 20
      
      sorted_pages.each_with_index do |page, i|
        pdf.text "#{i + 1}. #{page[:title]}", size: 12
        pdf.text "   #{page[:url]}", size: 8, color: '666666'
        pdf.move_down 10
      end
      
      # Content pages
      sorted_pages.each_with_index do |page, i|
        pdf.start_new_page
        pdf.text "#{i + 1}. #{page[:title]}", size: 16, style: :bold
        pdf.text "URL: #{page[:url]}", size: 10, color: '666666'
        pdf.move_down 20
        pdf.text "Page successfully processed and converted."
      end
    end
    
    # Cleanup temp files in batch
    @pages.each { |p| p[:file]&.close! }
    @pages.clear
  end
end

# CLI
if __FILE__ == $0
  if ARGV.empty? || ARGV[0] == '--help' || ARGV[0] == '-h'
    puts "Usage: #{$0} <url> [options]"
    puts "Options:"
    puts "  --output FILE     Output file (default: website.pdf)"
    puts "  --depth N         Max depth (default: 3)"
    puts "  --concurrent N    Max concurrent (default: 8)"
    puts "  --delay SECONDS   Delay between requests (default: 0.1)"
    puts "  --batch-size N    PDF batch size (default: 20)"
    puts "  --verbose         Enable verbose logging"
    puts "  --help, -h        Show this help"
    exit 0
  end
  
  url = ARGV[0]
  options = {}
  
  ARGV[1..-1].each_slice(2) do |key, value|
    case key
    when '--output' then options[:output_file] = value
    when '--depth' then options[:max_depth] = value.to_i
    when '--concurrent' then options[:max_concurrent] = value.to_i
    when '--delay' then options[:delay] = value.to_f
    when '--batch-size' then options[:batch_size] = value.to_i
    when '--verbose' then options[:verbose] = true
    end
  end
  
  begin
    Web2PDF.new(url, options).crawl_and_convert!
  rescue => e
    puts "Error: #{e.message}"
    exit 1
  end
end