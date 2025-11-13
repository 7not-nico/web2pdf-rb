# AGENTS.md

## Build/Test Commands

- **Install dependencies**: `bundle install`
- **Run tests**: `bundle exec rspec`
- **Run single test**: `bundle exec rspec spec/web2pdf_spec.rb:LINE_NUMBER`
- **Lint code**: `bundle exec rubocop`
- **Auto-fix linting**: `bundle exec rubocop -a`
- **Check syntax**: `ruby -c filename.rb`

## Code Style Guidelines

### Ruby Conventions
- Use 2-space indentation, follow RuboCop style guide
- snake_case for variables/methods, PascalCase for classes
- Prefer single quotes unless interpolation needed
- Keep methods under 15 lines, classes under 200 lines

### Import Organization
- Require stdlib gems first, then third-party alphabetically
- Group related requires together, avoid bundler/setup in individual files
- Use `require_relative` for local files

### Error Handling
- Use specific exceptions (ArgumentError, StandardError)
- Always rescue with meaningful error messages
- Validate inputs early with descriptive messages
- Log errors with appropriate severity levels

### Performance & Concurrency
- Use Concurrent::Array/Set for thread-safe collections
- Implement rate limiting for web requests
- Process pages in parallel with ThreadPoolExecutor
- Stream PDFs to temp files to save memory

### Testing
- Write descriptive test names using `describe` and `it`
- Use `let` for test data setup, mock HTTP calls with WebMock
- Test both success and failure scenarios