# encoding: utf-8
module Sqeduler
  # Sqeduler::BaseWorker is class that provides common infrastructure for Sidekiq workers:
  # - Synchronization of jobs across multiple hosts `Sqeduler::BaseWorker.synchronize_jobs`.
  # - Basic callbacks for job events that child classes can observe.
  class BaseWorker
    include TimeDuration
    SIDEKIQ_DISABLED_JOBS = "sidekiq.disabled-jobs"

    def self.synchronize_jobs(mode, opts = {})
      @synchronize_jobs_mode = mode
      @synchronize_jobs_timeout = opts[:timeout] || 5.seconds
      @synchronize_jobs_expiration = opts[:expiration]
      unless @synchronize_jobs_expiration
        fail ArgumentError, ":expiration is required!"
      end
    end

    class << self
      attr_reader :synchronize_jobs_mode
      attr_reader :synchronize_jobs_timeout
      attr_reader :synchronize_jobs_expiration

      def enable
        Sidekiq.redis do |redis|
          redis.hdel(SIDEKIQ_DISABLED_JOBS, name)
          Service.logger.warn "#{name} has been enabled"
        end
      end

      def disable
        Sidekiq.redis do |redis|
          redis.hset(SIDEKIQ_DISABLED_JOBS, name, Time.now)
          Service.logger.warn "#{name} has been disabled"
        end
      end

      def disabled?
        Sidekiq.redis do |redis|
          v = redis.hexists(SIDEKIQ_DISABLED_JOBS, name)
          puts "DISABLED? #{v}"
          v
        end
      end

      def enabled?
        !disabled?
      end

      def lock_name(*args)
        if args.present?
          "#{name}-#{args.join}"
        else
          name
        end
      end
    end

    def perform(*args)
      before_start
      Service.logger.info "Starting #{self.class.name} #{start_time}"
      if self.class.disabled?
        Service.logger.warn "#{self.class.name} is currently disabled."
      elsif self.class.synchronize_jobs_mode == :one_at_a_time
        perform_synchronized
      else
        do_work(*args)
      end
      Service.logger.info "#{self.class.name} completed at #{end_time}. Total time #{total_time}"
      on_success
    rescue => e
      notify_and_raise(e)
    end

    private

    # provides an oppurtunity to log when the job has started to create a
    # stateful db record for this job run
    def before_start; end

    # callback for successful run of this job
    def on_success; end

    # callback for when failues in this job occur
    def on_failure(_e); end

    # callback for when a lock cannot be obtained
    def on_lock_timeout; end

    # callback for when the job expiration is too short, less < time it took
    # perform the actual work
    def on_schedule_collision; end

    def notify_exception(e)
      Service.handle_exception(e)
    end

    def perform_synchronized
      start = Time.now
      do_work_with_lock(*args)
      duration = Time.now - start
      return unless duration > self.class.synchronize_jobs_expiration
      Service.logger.warn(
        "#{self.class.name} took #{time_duration(duration)} but has an expiration of #{@expiration} sec. Beware of race conditions!"
      )
      on_schedule_collision
    end

    def do_work_with_lock(*args)
      RedisLock.with_lock(
        self.class.lock_name(*args),
        :expiration => self.class.synchronize_jobs_expiration,
        :timeout => self.class.synchronize_jobs_timeout
      ) do
        do_work(*args)
      end
    rescue RedisLock::LockTimeoutError
      Service.logger.warn(
        "#{self.class.name} unable to acquire lock '#{self.class.lock_name(*args)}'. Aborting."
      )
      on_lock_timeout
    end

    def start_time
      @start_time ||= Time.now
    end

    def end_time
      @end_time ||= Time.now
    end

    def total_time
      time_duration(end_time - start_time)
    end

    def time_elapsed
      time_duration(Time.now - start_time)
    end

    def notify_and_raise(e)
      on_failure(e)
      Service.logger.error "#{self.class.name} failed!"
      Service.logger.error e
      notify_exception(e)
      fail e
    end
  end
end
