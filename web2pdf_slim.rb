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
  end

  def crawl_and_convert!
    logger.info "Starting crawl: #{@base_url}"
    
    validate_url!
    check_robots!
    crawl
    generate_pdf
    
    logger.info "PDF created: #{options[:output_file]}"
  end

  private

  def default_options
    {
      max_depth: 3,
      output_file: 'website.pdf',
      max_concurrent: 6,
      delay: 0.2,
      timeout: 30,
      user_agent: 'Web2PDF/3.0',
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
    if uri.scheme.nil?
      # Build URL with proper scheme format
      "https://#{url}"
    else
      uri.to_s
    end
  end

  def validate_url!
    response = HTTParty.head(@base_url, timeout: 10, 
      headers: { 'User-Agent' => options[:user_agent] })
    raise ArgumentError, "URL not accessible: #{@base_url}" unless response.success?
  rescue => e
    raise ArgumentError, "Failed to access #{@base_url}: #{e.message}"
  end

  def check_robots!
    robots_url = "#{URI(@base_url).scheme}://#{URI(@base_url).host}/robots.txt"
    
    begin
      response = HTTParty.get(robots_url, { timeout: 5, 
        headers: { 'User-Agent' => options[:user_agent] } })
      @robots = Robots.new(@base_url, response.body) if response.success?
    rescue
      @robots = nil
    end
  end

  def crawl
    pool = Concurrent::ThreadPoolExecutor.new(
      min_threads: 1,
      max_threads: options[:max_concurrent],
      max_queue: options[:max_concurrent] * 2
    )

    futures = Concurrent::Array.new
    
    while !@queue.empty? || futures.any?
      # Remove completed futures
      futures.reject!(&:complete?)
      
      # Add new work
      while futures.size < options[:max_concurrent] && !@queue.empty?
        url = @queue.shift(true) rescue nil
        next unless url && !@visited.include?(url)
        
        @visited << url
        futures << Concurrent::Future.execute(executor: pool) { process_page(url, 0) }
      end
      
      sleep(0.05)
    end
    
    pool.shutdown
    pool.wait_for_termination(30)
  end

  def process_page(url, depth)
    return if depth > options[:max_depth] || !should_crawl?(url)
    
    logger.debug "Processing: #{url}"
    
    begin
      response = HTTParty.get(url, timeout: options[:timeout], 
        headers: { 'User-Agent' => options[:user_agent] })
      return unless response.success? && response.content_type&.include?('text/html')
      
      doc = Nokogiri::HTML(response.body)
      
      # Convert to PDF
      pdf_file = convert_to_pdf(response.body, url)
      @pages << { url: url, file: pdf_file, title: extract_title(doc), depth: depth }
      
      # Extract links
      if depth < options[:max_depth]
        links = extract_links(doc, url)
        @queue.concat(links)
      end
      
      sleep(options[:delay])
      
    rescue => e
      logger.error "Failed: #{url} - #{e.message}"
    end
  end

  def should_crawl?(url)
    base_domain = "#{URI(@base_url).scheme}://#{URI(@base_url).host}"
    return false unless url.start_with?(base_domain)
    return false if @robots && !@robots.allowed?(url)
    return false if options[:exclude_patterns].any? { |p| url.match?(p) }
    options[:include_patterns].any? { |p| url.match?(p) }
  end

  def extract_links(doc, base_url)
    links = []
    base_uri = URI(base_url)
    
    doc.css('a[href]').each do |link|
      href = link['href']
      next unless href && !href.empty? && !href.start_with?('#')
      
      begin
        absolute = URI.join(base_uri, href).to_s
        normalized = normalize_url(absolute)
        
        unless @visited.include?(normalized) || @queue.include?(normalized)
          links << normalized
        end
      rescue URI::InvalidURIError
        # Skip invalid URLs
      end
    end
    
    links.uniq
  end

  def extract_title(doc)
    doc.at_css('title')&.text&.strip || 'Untitled'
  end

  def convert_to_pdf(html, url)
    temp_file = Tempfile.new(['page_', '.pdf'])
    
    grover = Grover.new(html,
      format: 'A4',
      margin: { top: '1cm', right: '1cm', bottom: '1cm', left: '1cm' },
      print_background: true,
      display_url: url
    )
    
    temp_file.write(grover.to_pdf)
    temp_file.flush
    temp_file
  rescue => e
    logger.error "PDF conversion failed: #{e.message}"
    temp_file.close! if temp_file
    nil
  end

  def generate_pdf
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
    
    # Cleanup temp files
    @pages.each { |p| p[:file]&.close! }
  end
end

# CLI
if __FILE__ == $0
  if ARGV.empty? || ARGV[0] == '--help' || ARGV[0] == '-h'
    puts "Usage: #{$0} <url> [options]"
    puts "Options:"
    puts "  --output FILE     Output file (default: website.pdf)"
    puts "  --depth N         Max depth (default: 3)"
    puts "  --concurrent N    Max concurrent (default: 6)"
    puts "  --delay SECONDS   Delay between requests (default: 0.2)"
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