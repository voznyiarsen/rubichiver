# frozen_string_literal: true

require_relative 'test_helper'

class RateLimiterTest < Minitest::Test
  def test_counts_requests
    rl = RateLimiter.new(requests_per_second: 1000)
    assert_equal 0, rl.request_count
    3.times { rl.throttle! }
    assert_equal 3, rl.request_count
  end

  def test_enforces_minimum_interval
    rl = RateLimiter.new(requests_per_second: 20)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    3.times { rl.throttle! }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    assert_operator elapsed, :>=, 0.08
  end

  def test_allows_immediate_first_call
    rl = RateLimiter.new(requests_per_second: 1)
    start = Time.now
    rl.throttle!
    assert (Time.now - start) < 0.1
    assert_equal 1, rl.request_count
  end

  def test_thread_safety
    rl = RateLimiter.new(requests_per_second: 1000)
    threads = 10.times.map do
      Thread.new { 100.times { rl.throttle! } }
    end
    threads.each(&:join)
    assert_equal 1000, rl.request_count
  end
end

# The pool exists so the rate is a per-worker budget: widening the worker pool
# has to actually buy throughput, which a single shared limiter made impossible.
class RateLimiterPoolTest < Minitest::Test
  def test_counts_requests_across_workers
    pool = RateLimiterPool.new(requests_per_second: 1000, threads: 4)
    assert_equal 0, pool.request_count
    3.times { |i| pool.throttle!(i) }
    assert_equal 3, pool.request_count
  end

  # One shared limiter would serialise these to a single worker's pace, so the
  # whole point is that N workers finish in roughly the time one takes.
  def test_workers_are_not_serialised_against_each_other
    pool = RateLimiterPool.new(requests_per_second: 4, threads: 4)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    4.times { |i| pool.throttle!(i) }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

    # Each worker may only spend 0.25s on its own first request; a shared
    # limiter would need four of those in sequence.
    assert_operator elapsed, :<, 0.6
  end

  def test_a_single_worker_is_still_throttled
    pool = RateLimiterPool.new(requests_per_second: 10, threads: 1)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    3.times { pool.throttle!(0) }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    assert_operator elapsed, :>=, 0.15
  end

  # Threads with no declared index (the main thread fetching tag queries) still
  # get their own budget rather than contending for a worker's.
  def test_unkeyed_callers_are_separated_by_thread
    pool = RateLimiterPool.new(requests_per_second: 4, threads: 2)
    threads = 4.times.map { Thread.new { pool.throttle! } }
    threads.each(&:join)
    assert_equal 4, pool.request_count
  end

  # More threads than declared must not grow the pool without bound.
  def test_extra_threads_share_a_limiter
    pool = RateLimiterPool.new(requests_per_second: 1000, threads: 1)
    threads = 20.times.map { Thread.new { pool.throttle! } }
    threads.each(&:join)
    assert_equal 20, pool.request_count
  end

  def test_a_plain_limiter_can_be_passed_straight_through
    pool = RateLimiterPool.new(requests_per_second: 1000, threads: 1)
    limiter = RateLimiter.new(requests_per_second: 1000)
    pool.throttle!(limiter)
    assert_equal 1, pool.request_count
    assert_equal 1, limiter.request_count
  end
end
