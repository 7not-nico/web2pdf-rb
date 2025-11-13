#!/usr/bin/env ruby

require 'bundler/setup'
require 'benchmark'
require 'webmock'
require 'fileutils'

# Disable external HTTP requests for consistent benchmarking
WebMock.disable_net_connect!(allow_localhost: true)

# Mock HTTP requests for all versions
base_url = 'https://example.com'
WebMock.stub_request(:head, /example\.com/).to_return(status: 200, headers: { 'Content-Type' => 'text/html' })
WebMock.stub_request(:get, /.*robots\.txt/).to_return(status: 404)
WebMock.stub_request(:get, base_url).to_return(
  status: 200,
  headers: { 'Content-Type' => 'text/html' },
  body: '<html><head><title>Test</title></head><body><a href="/page1">Page 1</a><a href="/page2">Page 2</a></body></html>'
)
WebMock.stub_request(:get, /.*page\d/).to_return(
  status: 200,
  headers: { 'Content-Type' => 'text/html' },
  body: '<html><head><title>Page</title></head><body></body></html>'
)

puts "Web2PDF Performance Benchmark"
puts "=" * 50
puts "Testing all three versions with identical mock data"
puts

options = {
  max_depth: 2,
  output_file: 'benchmark.pdf',
  verbose: false,
  max_concurrent: 4,
  delay: 0.0  # No delay for benchmarking
}

results = {}

# Benchmark Main Version
puts "Testing web2pdf.rb (Main Version)..."
results[:main] = Benchmark.measure do
  3.times do |i|
    File.delete("benchmark_main_#{i}.pdf") if File.exist?("benchmark_main_#{i}.pdf")
    
    load 'web2pdf.rb'
    crawler = Web2PDF.new(base_url, options.merge(output_file: "benchmark_main_#{i}.pdf"))
    crawler.crawl_and_convert!
  end
end

# Benchmark KISS Version  
puts "Testing web2pdf_slim.rb (KISS Version)..."
results[:slim] = Benchmark.measure do
  3.times do |i|
    File.delete("benchmark_slim_#{i}.pdf") if File.exist?("benchmark_slim_#{i}.pdf")
    
    load 'web2pdf_slim.rb'
    crawler = Web2PDF.new(base_url, options.merge(output_file: "benchmark_slim_#{i}.pdf"))
    crawler.crawl_and_convert!
  end
end

# Benchmark Performance Version
puts "Testing web2pdf_performance.rb (Optimized Version)..."
results[:performance] = Benchmark.measure do
  3.times do |i|
    File.delete("benchmark_perf_#{i}.pdf") if File.exist?("benchmark_perf_#{i}.pdf")
    
    load 'web2pdf_performance.rb'
    crawler = Web2PDF.new(base_url, options.merge(output_file: "benchmark_perf_#{i}.pdf"))
    crawler.crawl_and_convert!
  end
end

# Cleanup benchmark files
Dir.glob('benchmark_*.pdf').each { |f| File.delete(f) }

puts
puts "Benchmark Results (3 runs each):"
puts "-" * 50

results.each do |version, time|
  puts sprintf("%-20s %8.3f seconds", version.to_s.capitalize, time.real)
end

puts
puts "Performance Comparison:"
puts "-" * 50

baseline = results[:main].real
results.each do |version, time|
  speedup = baseline / time.real
  puts sprintf("%-20s %8.3fx speedup", version.to_s.capitalize, speedup)
end

puts
puts "Memory Usage Estimates:"
puts "-" * 50
puts "Main Version:        High (stores all PDFs in memory)"
puts "KISS Version:        Medium (streaming to temp files)"  
puts "Performance Version:  Low (batched processing + streaming)"

puts
puts "Feature Comparison:"
puts "-" * 50
puts "Main Version:        Full features, 480+ lines"
puts "KISS Version:        Core features, 180 lines"
puts "Performance Version:  Optimized features, 306 lines"