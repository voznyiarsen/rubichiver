# frozen_string_literal: true

# Thread-safe rate limiter using a reservation-based mutex.
# A single critical section reserves the next allowed time slot, so the
# configured rate is actually enforced across multiple threads (the previous
# implementation slept outside the mutex, allowing bursts).
#
# Scheduling uses the monotonic clock: a wall-clock adjustment (NTP step)
# would otherwise either stall the run for a full interval or let a burst
# through.
class RateLimiter
  attr_reader :request_count, :requests_per_second

  def initialize(requests_per_second: 2)
    @mutex = Mutex.new
    @requests_per_second = requests_per_second.to_f
    @min_interval = 1.0 / @requests_per_second
    # Seed one interval in the past so the very first call is immediate.
    @next_allowed = monotonic_now - @min_interval
    @request_count = 0
  end

  # Changing the rate takes effect on the next call and never lets a burst
  # through to "catch up": halving the speed has to actually halve it from this
  # moment, not after a backlog built up at the old rate has drained.
  def requests_per_second=(rate)
    @mutex.synchronize do
      @requests_per_second = rate.to_f
      @min_interval = 1.0 / @requests_per_second
      @next_allowed = [@next_allowed, monotonic_now + @min_interval].max
    end
  end

  def throttle!
    target = @mutex.synchronize do
      now = monotonic_now
      target = [@next_allowed, now].max
      @next_allowed = target + @min_interval
      target
    end

    sleep_time = target - monotonic_now
    sleep(sleep_time) if sleep_time > 0

    @mutex.synchronize { @request_count += 1 }
  end

  private

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end

# A rate limit is a budget per worker, not a ceiling for the whole run.
#
# One limiter shared by every thread caps the *run* at the configured rate no
# matter how many workers there are, so widening the worker pool bought nothing
# and the only way to go faster was to raise a number that then overran the site
# as well. Each caller gets its own limiter instead, so N workers at 2 req/s can
# sustain 2N req/s between them.
#
# The pool also knows how to back off. A site that answers "slow down" should not
# require someone to be watching: throttling moves the pool through gentler
# stages for a fixed window and then lifts the restriction by itself, so a run
# recovers on its own instead of staying throttled for the rest of the night.
class RateLimiterPool
  # One extra limiter for the main thread, which fetches tag queries, pool
  # members and repair work itself rather than through a worker.
  EXTRA_THREADS = 1

  def initialize(requests_per_second: 2, threads: 1, cooldown: 60, stages: 2, clock: nil)
    @base_rate = requests_per_second.to_f
    @threads = [threads.to_i, 1].max
    @cooldown = cooldown
    @stages = [stages.to_i, 1].max
    # Injectable so the escalation policy can be tested without a test that
    # sleeps for a minute to prove a minute passed.
    @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    @limiters = Array.new(@threads + EXTRA_THREADS) do
      RateLimiter.new(requests_per_second: @base_rate)
    end
    @by_thread = {}
    @map_mutex = Mutex.new
    @counter_mutex = Mutex.new
    @request_count = 0
    @stage_mutex = Mutex.new
    @stage = 0
    @stage_until = nil
    @stage_changed_at = nil
    @applied_stage = -1
  end

  # Records that the site refused a request, and answers [stage, escalated].
  #
  # Escalation is gated on a stage having been held for a whole window, because
  # a single refused request is retried several times in a row: without the gate
  # one unlucky request would walk straight through every stage in a second and
  # leave the run crawling at the floor for minutes. Instead, being refused once
  # means "back off for a minute", and only being refused *again after that
  # minute* means "we are still too fast, go slower still".
  def note_refusal
    @stage_mutex.synchronize do
      now = @clock.call
      escalated = false

      if @stage.zero?
        @stage = 1
        @stage_changed_at = now
        escalated = true
      elsif now - @stage_changed_at >= @cooldown
        raised = [@stage + 1, @stages].min
        if raised > @stage
          @stage = raised
          @stage_changed_at = now
        end
        escalated = true
      end

      @stage_until = now + @cooldown
      [@stage, escalated]
    end
  end

  # @param key [Integer, Thread, nil] the worker index when the caller knows it,
  #   otherwise the calling thread. Passing a RateLimiter straight through keeps
  #   a single limiter usable wherever a pool is.
  def throttle!(key = nil)
    limiter = key.is_a?(RateLimiter) ? key : limiter_for(key)
    sync_stage
    limiter.throttle!
    @counter_mutex.synchronize { @request_count += 1 }
  end

  # Every request made through the pool, so the run summary still reports one
  # meaningful total rather than a per-worker figure.
  def request_count
    @counter_mutex.synchronize { @request_count }
  end

  # Holds the pool at `stage` for `seconds`, then returns to the configured rate
  # on its own. Stage 0 is the configured rate; each stage above it is gentler.
  def hold_stage(stage, seconds)
    @stage_mutex.synchronize do
      now = @clock.call
      @stage = stage
      @stage_until = now + seconds
      @stage_changed_at = now
      @applied_stage = -1 # force the new rate onto the limiters
    end
  end

  # The stage actually in force right now: a held stage, or 0 once its window
  # has passed.
  def current_stage
    @stage_mutex.synchronize do
      (@stage_until && @clock.call < @stage_until) ? @stage : 0
    end
  end

  # True while a throttle window is open, i.e. the site is still refusing us.
  def throttled?
    current_stage.positive?
  end

  def threads
    @threads
  end

  private

  # Pushes the staged rate onto the limiters, but only when the stage actually
  # changed -- this runs on every request and must stay cheap.
  def sync_stage
    active = current_stage
    return if active == @applied_stage

    @stage_mutex.synchronize do
      active = (@stage_until && @clock.call < @stage_until) ? @stage : 0
      return if active == @applied_stage

      rate = stage_rate(active)
      @limiters.each { |limiter| limiter.requests_per_second = rate }
      @applied_stage = active
    end
  end

  # A total budget divided among the workers, so N workers together stay within
  # the requested total rather than each being allowed the whole of it.
  def stage_rate(stage)
    case stage
    when 0 then @base_rate          # configured per-worker rate
    when 1 then 1.0                 # 1 req/s per worker
    else 1.0 / @threads             # 1 req/s in total
    end
  end

  def monotonic_now
    @clock.call
  end

  def limiter_for(key)
    return @limiters[key] if key.is_a?(Integer) && key < @limiters.size

    thread = key || Thread.current
    cached = @by_thread[thread]
    return cached if cached

    @map_mutex.synchronize do
      @by_thread[thread] ||= begin
        # Bounded: threads beyond the pool share a limiter rather than growing
        # it without limit. Only reachable if a caller spawns more threads than
        # it declared.
        @by_thread.size < @limiters.size ? @limiters[@by_thread.size] : @limiters.last
      end
    end
  end
end