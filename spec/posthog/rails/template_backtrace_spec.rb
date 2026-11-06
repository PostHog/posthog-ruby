# frozen_string_literal: true

require 'spec_helper'
require 'rails'
require 'action_view'
require 'tmpdir'
require 'fileutils'

RSpec.describe 'Rails template backtraces' do
  let(:capture) { PostHog::ExceptionCapture }
  let(:root) { '/app/releases/20261106' }
  let(:file) { "#{root}/app/views/orders/show.html.erb" }
  let(:function) { '_app_views_orders_show_html_erb' }

  before { allow(Rails).to receive(:root).and_return(Pathname.new(root)) }

  %w[123_456 _123_456 123__456 _123__456].each do |components|
    ['`', "'"].each do |quote|
      ['', 'block in ', 'block (2 levels) in '].each do |prefix|
        it "cleans generated components #{components} with #{quote} quoting and #{prefix.inspect}" do
          frame = capture.parse_backtrace_line("#{file}:7:in #{quote}#{prefix}#{function}__#{components}'")

          expect(frame).to eq(
            'filename' => 'app/views/orders/show.html.erb',
            'abs_path' => file,
            'lineno' => 7,
            'function' => "#{prefix}#{function}",
            'in_app' => true,
            'platform' => 'ruby'
          )
        end
      end
    end
  end

  it 'handles identifiers ending in encoded punctuation or digits' do
    path = "#{root}/custom/views/Order-v2.html.erb2"
    frame = capture.parse_backtrace_line("#{path}:7:in '_custom_views__rder_v__html_erb____123_456'")

    expect(frame['function']).to eq('_custom_views__rder_v__html_erb_')
  end

  it 'handles full identifiers when Rails has no application root' do
    allow(Rails).to receive(:root).and_return(nil)
    frame = capture.parse_backtrace_line(
      "#{file}:7:in '__app_releases__________app_views_orders_show_html_erb__123_456'"
    )

    expect(frame['function']).to eq('__app_releases__________app_views_orders_show_html_erb')
  end

  it 'leaves ordinary application methods and incomplete generated names unchanged' do
    %W[show show_123_456 #{function} #{function}__123 #{function}__123_456_extra].each do |name|
      frame = capture.parse_backtrace_line("#{file}:7:in '#{name}'")

      expect(frame['function']).to eq(name)
    end
    expect(capture.parse_backtrace_line("#{file}:7")['function']).to be_nil
  end

  it 'does not clean names that do not match the source path' do
    ['/app/lib/renderer.rb', "#{root}/app/views/orders/edit.html.erb"].each do |path|
      frame = capture.parse_backtrace_line("#{path}:7:in '#{function}__123_456'")

      expect(frame['function']).to eq("#{function}__123_456")
    end
  end

  it 'leaves generated-looking names unchanged without Rails' do
    hide_const('Rails')
    frame = capture.parse_backtrace_line("#{file}:7:in '#{function}__123_456'", project_root: root)

    expect(frame['function']).to eq("#{function}__123_456")
  end

  it 'preserves dependency classification for templates outside the project' do
    path = File.join(Gem.path.first, 'gems', 'view_pack', 'show.html.erb')
    template = ActionView::Template.new('', path, ActionView::Template.handler_for_extension(:erb), locals: [])
    name = "_#{path.tr('^a-z_', '_')}"
    frame = capture.parse_backtrace_line("#{path}:7:in '#{template.method_name}'")

    expect(frame['function']).to eq(name)
    expect(frame['filename']).to eq('show.html.erb')
    expect(frame['abs_path']).to eq(path)
    expect(frame['in_app']).to be(false)
    expect(frame).not_to have_key('context_line')
  end

  it 'cleans a real rendered template cause without changing stack data or deduplication' do
    Dir.mktmpdir('posthog-template') do |directory|
      allow(Rails).to receive(:root).and_return(Pathname.new(directory))
      path = File.join(directory, 'app/views/orders/show.html.erb')
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "before\n<% [1].each do %>\n<% raise 'template failed' %>\n<% end %>\nafter\n")
      template = ActionView::Template.new(
        File.read(path), path, ActionView::Template.handler_for_extension(:erb), locals: []
      )
      view = ActionView::Base.with_empty_template_cache.new(ActionView::LookupContext.new([]), {}, nil)
      error = begin
        template.render(view, {})
      rescue ActionView::Template::Error => e
        e
      end
      expect(error).to be_a(ActionView::Template::Error)
      expect(error.cause).to be_a(RuntimeError)
      original_backtraces = [error.backtrace.dup, error.cause.backtrace.dup]
      client = PostHog::Client.new(api_key: API_KEY, test_mode: true)

      expect(client.capture_exception(error)).to be(true)
      expect(client.capture_exception(error)).to be(false)
      expect(client.capture_exception(error.cause)).to be(false)
      expect(client.queued_messages).to eq(1)
      entries = client.dequeue_last_message[:properties]['$exception_list']
      expect(entries.map { |entry| entry['type'] }).to eq(['ActionView::Template::Error', 'RuntimeError'])
      entries.each_with_index do |entry, index|
        frames = entry['stacktrace']['frames']
        expect(frames.size).to eq(original_backtraces[index].first(50).size)
        template_frames = frames.select { |frame| frame['abs_path'] == path }
        expect(template_frames).not_to be_empty
        expect(template_frames.last).to include(
          'function' => "block in #{function}",
          'filename' => 'app/views/orders/show.html.erb',
          'lineno' => 3,
          'in_app' => true,
          'context_line' => "<% raise 'template failed' %>",
          'pre_context' => ['before', '<% [1].each do %>'],
          'post_context' => ['<% end %>', 'after']
        )
      end
      expect([error.backtrace, error.cause.backtrace]).to eq(original_backtraces)
    end
  end
end
