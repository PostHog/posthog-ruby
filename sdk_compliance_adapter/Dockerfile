FROM ruby:3.3-slim

WORKDIR /app

RUN gem install concurrent-ruby --no-document

COPY lib/ /app/lib/
COPY sdk_compliance_adapter/adapter.rb /app/adapter.rb

ENV RUBYLIB=/app/lib

EXPOSE 8080

CMD ["ruby", "/app/adapter.rb"]
