# frozen_string_literal: true

module OnlineMigrations
  module BackgroundMigrations
    class MigrationJob < ActiveRecord::Base
      STATUSES = [
        :enqueued,
        :running,
        :failed,
        :succeeded,
      ]

      self.table_name = :background_migration_jobs

      # For Active Record <= 4.2 needs to fully specify enum values
      scope :active, -> { where(status: [statuses[:enqueued], statuses[:running]]) }
      scope :completed, -> { where(status: [statuses[:failed], statuses[:succeeded]]) }
      scope :stuck, -> do
        timeout = ::OnlineMigrations.config.background_migrations.stuck_jobs_timeout
        active.where("updated_at <= ?", timeout.ago)
      end

      scope :retriable, -> do
        failed_retriable = failed.where("attempts < max_attempts")

        stuck_sql             = connection.unprepared_statement { stuck.to_sql }
        failed_retriable_sql  = connection.unprepared_statement { failed_retriable.to_sql }

        from(Arel.sql(<<-SQL.strip_heredoc))
          (
            (#{failed_retriable_sql})
            UNION
            (#{stuck_sql})
          ) AS #{table_name}
        SQL
      end

      scope :except_succeeded, -> { where("status != ?", statuses[:succeeded]) }
      scope :attempts_exceeded, -> { where("attempts >= max_attempts") }

      enum status: STATUSES.map { |status| [status, status.to_s] }.to_h

      delegate :migration_class, :migration_object, :migration_relation, :batch_column_name,
        :arguments, :batch_pause, to: :migration

      belongs_to :migration

      # For Active Record 5.0+ this is validated by default from belongs_to
      validates :migration, presence: true

      validates :min_value, :max_value, presence: true, numericality: { greater_than: 0 }
      validate :values_in_migration_range, if: :min_value?
      validate :validate_values_order, if: :min_value?

      validates_with MigrationJobStatusValidator, on: :update

      before_create :copy_settings_from_migration

      # Mark this job as ready to be processed again.
      #
      # This is used when retrying failed jobs.
      #
      def retry
        update!(
          status: self.class.statuses[:enqueued],
          attempts: 0,
          started_at: nil,
          finished_at: nil
        )
      end

      private
        def values_in_migration_range
          if min_value < migration.min_value || max_value > migration.max_value
            errors.add(:base, "min_value and max_value should be in background migration values range")
          end
        end

        def validate_values_order
          if max_value.to_i < min_value.to_i
            errors.add(:base, "max_value should be greater than or equal to min_value")
          end
        end

        def copy_settings_from_migration
          self.batch_size       = migration.batch_size
          self.sub_batch_size   = migration.sub_batch_size
          self.pause_ms         = migration.sub_batch_pause_ms
          self.max_attempts     = migration.batch_max_attempts
        end
    end
  end
end
