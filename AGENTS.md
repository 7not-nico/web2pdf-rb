# AGENTS.md

## Build/Test Commands

- **Install dependencies**: `bundle install`
- **Run tests**: `bundle exec rspec`
- **Run single test**: `bundle exec rspec spec/web2pdf_spec.rb:LINE_NUMBER`
- **Lint code**: `bundle exec rubocop`
- **Auto-fix linting**: `bundle exec rubocop -a`
- **Setup project**: `./setup.sh`

## Code Style Guidelines

### Ruby Conventions
- Use 2-space indentation
- Follow RuboCop style guide (Ruby 2.7+ compatible)
- Use snake_case for variables and methods
- Use PascalCase for classes
- Prefer single quotes for strings unless interpolation needed

### Import Organization
- Require stdlib gems first
- Require third-party gems alphabetically
- Require relative files last
- Group related requires together

### Error Handling
- Use specific exception classes
- Always rescue with meaningful error messages
- Log errors with appropriate severity levels
- Validate inputs early with descriptive messages

### Testing
- Write descriptive test names using `describe` and `it`
- Use `let` for test data setup
- Mock external HTTP calls with WebMock
- Test both success and failure scenarios

### Performance
- Use Concurrent::Array/Set for thread-safe collections
- Implement rate limiting for web requests
- Process pages in parallel with ThreadPoolExecutor
- Cache robots.txt responses per domain