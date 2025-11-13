#!/usr/bin/env ruby

require 'bundler/setup'
require 'httparty'
require 'nokogiri'
require 'addressable/uri'

class DebugCrawl
  def initialize(url)
    @base_url = normalize_url(url)
    @visited = Set.new
    @queue = [@base_url]
  end

  def normalize_url(url)
    uri = Addressable::URI.parse(url)
    uri.scheme ||= 'https'
    uri.normalize.to_s
  end

  def crawl_simple(depth = 1, current_depth = 0)
    return if current_depth > depth
    
    urls_to_process = @queue.dup
    @queue.clear
    
    urls_to_process.each do |url|
      next if @visited.include?(url)
      @visited << url
      
      puts "Processing: #{url} (depth: #{current_depth})"
      
      begin
        response = HTTParty.get(url, timeout: 10, follow_redirects: true)
        next unless response.success?
        next unless response.content_type&.include?('text/html')
        
        doc = Nokogiri::HTML(response.body)
        
        if current_depth < depth
          links = extract_links(doc, url)
          puts "Found #{links.size} links: #{links.first(3).join(', ')}" if links.any?
          @queue.concat(links)
        end
        
      rescue => e
        puts "Error: #{e.message}"
      end
    end
    
    crawl_simple(depth, current_depth + 1) if @queue.any?
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
        
        unless @visited.include?(normalized_url)
          links << normalized_url
        end
      rescue URI::InvalidURIError
        # Skip invalid URLs
      end
    end
    
    links.uniq
  end
end

if __FILE__ == $0
  url = ARGV[0] || 'https://geminicli.com/docs/'
  crawler = DebugCrawl.new(url)
  crawler.crawl_simple(1)
  puts "Total URLs visited: #{crawler.instance_variable_get(:@visited).size}"
end
