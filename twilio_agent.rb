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
@tw_acc = @twilio.account

# Configure NewRelic client
@new_relic = NewRelic::Client.new(:license => config['newrelic']['license'],
                                  :guid => config['newrelic']['guid'],
                                  :version => config['newrelic']['version'])

# Configure IronCache client
ic = IronCache::Client.new(config['iron'])
@cache = ic.cache("newrelic-twilio-agent")

# Helpers

# New Relic allows duration less than one hour
def duration(from, to)
  dur = from ? (to - from).to_i : 3600

  dur > 3600 ? 3600 : dur
end

def daily_processed_at(processed = nil)
  if processed
    @cache.put('daily_previously_processed_at', processed.to_i)

    @at = processed
  else
    item = @cache.get 'daily_previously_processed_at'

    @at ||= item ? item.value : nil
  end
end

def process_dates_since
  now = Time.now.utc
  today = now.to_date
  yesterday = today.yesterday.to_time :utc

  dates = [today]

  # get from cache
  previously_at = daily_processed_at
  since = if previously_at
            at = Time.at(previously_at).utc
            puts "Previously processed at: #{at}"
            # no earlier than yesterday
            (at < yesterday) ? yesterday : at
          else # first run
            today.to_time :utc
          end

  since_d = since.to_date
  # since yesterday and now < 12:59am, 3600 seconds max duration
  if since_d != today && now.hour == 0 && now.min < 59
    dates << since_d
  end

  [dates, since]
end

def make_metric_record(name, unit, value)
  puts "#{name} #{unit}: #{value}"

  (unit.blank? || value.blank?) ? [] : [name, unit, value]
end

def process_daily
  today = Time.now.utc.to_date
  dates, since = process_dates_since

  processed_at = nil
  dates.each do |date|
    collector = @new_relic.new_collector

    yield date, collector

    processed_at = Time.now.utc
    # update duration
    current_duration = duration(since, processed_at)
    collector.components.each_pair do |_, component|
      component.options[:duration] = current_duration
    end
    # submit statistics
    collector.submit

    # workaround for daily data with durable New Relic recording system
    unless since.to_date == today
      since = today.to_time :utc
      # New Relic does not accept data more than twice a minute
      sleep 30
    end
  end
  puts "Processed at #{processed_at}"

  daily_processed_at(processed_at.to_i)
end

def collect_component_data(name, collector)
  puts "Processing: #{name}"
  prefix = name.gsub(/[^a-zA-Z0-9]/, '_').downcase.camelize
  component = collector.component 'Twilio'

  data = []
  yield data, prefix

  data.each do |metric|
    component.add_metric(*metric) unless metric.empty?
  end
end


# Process statistics

process_daily do |for_date, collector|
  # Today Calls
  collect_component_data('Today Calls', collector) do |stats, prefix|
    opts = {:start_time => for_date}
    TWILIO_CALL_STATUSES.each do |status|
      opts[:status] = status
      value = @tw_acc.calls.list(opts).total
      name = "#{prefix}/#{status.capitalize}"

      stats << make_metric_record(name, 'calls', value)
    end
  end

  # Today SMSs
  # Twilio has no filter by status for SMS logs,
  # this could be very slow on huge SMS amount
  collect_component_data('Today SMS', collector) do |stats, prefix|
    collection = TWILIO_SMS_STATUSES.each_with_object({}) { |s, res| res[s] = 0 }
    sms = @tw_acc.sms.messages.list({:date_sent => for_date})
    # collect all stats for date first
    begin
      sms.each { |msg| collection[msg.status.to_s] += 1 }
      sms = sms.next_page
    end while not sms.empty?

    collection.each_pair do |name, value|
      name = "#{prefix}/#{name.capitalize}"
      stats << make_metric_record(name, 'messages', value)
    end
  end

  # Today Usage
  collect_component_data('Today Usage', collector) do |stats, prefix|
    @tw_acc.usage.records.list({:start_date => for_date}).each do |record|
      ['count', 'usage', 'price'].each do |submetric|
        name = "#{prefix}/#{record.category.capitalize}/#{submetric.capitalize}"
        unit = record.send "#{submetric}_unit"
        value = record.send "#{submetric}"
        value = submetric == 'price' ? value.to_f : value.to_i

        stats << make_metric_record(name, unit, value)
      end
    end
  end
end
