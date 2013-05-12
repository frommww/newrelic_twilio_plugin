require 'yaml'
require 'twilio-ruby'
require 'base64'
require 'iron_cache'
require 'active_support/core_ext'
# Requires manual installation of the New Relic plaform gem
# https://github.com/newrelic-platform/iron_sdk
require 'newrelic_platform'

# Un-comment to test/debug locally
# config = YAML.load_file('./twilio_agent.config.yml')

# Setup
# Twilio calls statuses
TWILIO_CALL_STATUSES =
  %w(queued ringing in-progress canceled completed failed busy no-answer)
TWILIO_SMS_STATUSES = %w(queued sending sent failed received)


# Configure Twilio client
@twilio = Twilio::REST::Client.new(config['twilio']['account_sid'],
                                   config['twilio']['auth_token'])

# Configure NewRelic client
@new_relic = NewRelic::Client.new(:license => config['newrelic']['license'],
                                  :guid => config['newrelic']['guid'],
                                  :version => config['newrelic']['version'])

# Configure IronCache client
ic = IronCache::Client.new(config['iron'])
@cache = ic.cache("newrelic-twilio-agent")

# Helpers

def duration(from, to)
  # do it Lisp-like (:
  (from ? (to - from) : (to - to.beginning_of_day)).to_i
end

def make_metric_record(name, unit, value)
  puts "#{name} #{unit}: #{value}"
  [name, unit, value]
end

def daily_process_since(previously_at)
  today = Time.now.utc.to_date
  dates = [today]

  yesterday = today.yesterday.to_time :utc
  since = if previously_at
            at = Time.at(previously_at).utc
            puts "Previously processed at: #{at}"
            # no earlier than yesterday
            (at < yesterday) ? yesterday : at
          else # first run
            today.to_time :utc
          end
  dates << since.to_date unless since.to_date == today

  dates.each do |date|
    yield date, since

    # workaround for daily data with durable New Relic recording system
    unless since.to_date == today
      since = today.to_time :utc
    end
  end
end

def submit_component_data(name)
  puts "Processing: #{name}"
  date_key = Base64.encode64 "#{name}_previously_processed_at"
  date_cache_item = @cache.get date_key
  prev_processed_at = date_cache_item ? date_cache_item.value : nil

  processed_at = nil
  daily_process_since(prev_processed_at) do |date, since|
    collector = @new_relic.new_collector
    component = collector.component name

    data = []
    yield data, date

    data.each { |metric| component.add_metric(*metric) }
    processed_at = Time.now.utc

    component.options[:duration] = duration(since, processed_at)
    puts "Duration is #{component.options[:duration]}"

    collector.submit

    processed_at
  end

  puts "#{name} processed at #{processed_at}"
  @cache.put(date_key, processed_at.to_i)
end

# Process statistics

# Today Calls
submit_component_data('Today Calls by Status') do |stats, for_date|
  opts = {:start_time => for_date}
  TWILIO_CALL_STATUSES.each do |status|
    opts[:status] = status
    value = @twilio.account.calls.list(opts).total

    stats << make_metric_record(status.capitalize, 'calls', value)
  end
end

# Today SMSs
# Twilio has no filter by status for SMS logs,
# this could be very slow on huge SMS amount
submit_component_data('Today SMSs by Status') do |stats, for_date|
  collection = TWILIO_SMS_STATUSES.each_with_object({}) { |s, res| res[s] = 0 }
  sms = @twilio.account.sms.messages.list({:date_sent => for_date})
  # collect all stats for date first
  begin
    sms.each { |msg| collection[msg.status.to_s] += 1 }
    sms = sms.next_page
  end while not sms.empty?

  collection.each_pair do |name, value|
    stats << make_metric_record(name.capitalize, 'messages', value)
  end
end

# Today Usage
submit_component_data('Today Usage') do |stats, for_date|
  @twilio.account.usage.records.list({:start_date => for_date}).each do |record|
    ['count', 'usage', 'price'].each do |submetric|
      name = "#{record.category.capitalize} #{submetric.capitalize}"
      unit = record.send "#{submetric}_unit"
      value = record.send "#{submetric}"

      stats << make_metric_record(name, unit, value)
    end
  end
end
