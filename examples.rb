#!/usr/bin/env ruby

require_relative 'web2pdf'

# Example usage script demonstrating various Web2PDF scenarios

puts "Web2PDF-Ruby Examples"
puts "=" * 50

# Example 1: Basic documentation site crawl
puts "\n1. Crawling Ruby documentation (depth 2)..."
begin
  crawler = Web2PDF.new(
    'https://ruby-doc.org/core-3.0.0/',
    {
      output_file: 'ruby-core-docs.pdf',
      max_depth: 2,
      concurrent: 3,
      delay: 1.0,
      verbose: true
    }
  )
  crawler.crawl_and_convert!
  puts "✓ Ruby documentation saved to ruby-core-docs.pdf"
rescue => e
  puts "✗ Error: #{e.message}"
end

# Example 2: Quick single page conversion
puts "\n2. Converting single page to PDF..."
begin
  crawler = Web2PDF.new(
    'https://httpbin.org/html',
    {
      output_file: 'httpbin-demo.pdf',
      max_depth: 1,
      verbose: false
    }
  )
  crawler.crawl_and_convert!
  puts "✓ Single page saved to httpbin-demo.pdf"
rescue => e
  puts "✗ Error: #{e.message}"
end

# Example 3: Blog crawling with custom filters
puts "\n3. Crawling blog with custom filters..."
begin
  crawler = Web2PDF.new(
    'https://blog.ruby-lang.org/',
    {
      output_file: 'ruby-blog.pdf',
      max_depth: 3,
      concurrent: 2,
      delay: 2.0,
      include_patterns: [/\d{4}\/\d{2}\/.*/, %r{/$}], # Blog posts and index pages
      exclude_patterns: [%r{\/feed\/}, %r{\/tag\/}], # Exclude feeds and tag pages
      verbose: true
    }
  )
  crawler.crawl_and_convert!
  puts "✓ Blog saved to ruby-blog.pdf"
rescue => e
  puts "✗ Error: #{e.message}"
end

puts "\n" + "=" * 50
puts "Examples completed! Check the generated PDF files."
puts "\nTo run individual examples:"
puts "  ruby examples.rb"
puts "  ./web2pdf.rb <url> --output <file> --depth <n>"