module ManageIQ::Providers
  class Hawkular::MiddlewareManager::MiddlewareJdrReport < ApplicationRecord
    self.table_name = 'middleware_jdr_reports'

    STATUS_QUEUED = 'Queued'.freeze
    STATUS_RUNNING = 'Running'.freeze
    STATUS_ERROR = 'Error'.freeze
    STATUS_READY = 'Ready'.freeze

    belongs_to :middleware_server
    has_one :binary_blob, :as => :resource, :dependent => :destroy

    validates :middleware_server_id, :requesting_user, :presence => true
    validates :status, :inclusion => { :in => [STATUS_QUEUED, STATUS_RUNNING, STATUS_ERROR, STATUS_READY] }

    delegate :ext_management_system, :to => :middleware_server
    delegate :ems_id, :to => :middleware_server
    after_create :enqueue_job
    before_create :set_queued_date

    after_initialize do |item|
      item.status = STATUS_QUEUED if new_record?
    end

    def queued?
      status == STATUS_QUEUED
    end

    def ready?
      status == STATUS_READY
    end

    def erred?
      status == STATUS_ERROR
    end

    def ran?
      ready? || erred?
    end

    def generate_jdr_report
      $mw_log.debug("#{log_prefix} Sending to Hawkular a request to generate JDR report [#{id}].")

      self.status = STATUS_RUNNING
      save!

      callback = proc do |on|
        on.success(&method(:jdr_report_succeded))
        on.failure(&method(:jdr_report_failed))
      end

      @connection = ext_management_system.connect.operations(true)
      @connection.export_jdr(middleware_server.ems_ref, true, &callback)
    end

    private

    def set_queued_date
      self.queued_at = Time.current if queued?
    end

    def enqueue_job
      unless queued?
        $mw_log.debug("#{log_prefix} JDR report registry [#{id}] for server [#{middleware_server.ems_ref}] created with status [#{status}].")
        return
      end

      job = MiqQueue.submit_job(
        :class_name  => self.class.name,
        :instance_id => id,
        :role        => 'ems_operations',
        :method_name => 'generate_jdr_report'
      )

      $mw_log.info("#{log_prefix} JDR report [#{id}] for server [#{middleware_server.ems_ref}] enqueued with job #{job.id}.")
    end

    def jdr_report_succeded(data)
      reload
      self.class.transaction(:isolation => :serializable) do
        if binary_blob
          $mw_log.debug("#{log_prefix} JDR report [#{id}] [#{binary_blob.name}] will be overwritten.")
          binary_blob.name = data['fileName']
          binary_blob.data_type = 'zip'
        else
          self.binary_blob = BinaryBlob.create(:name => data['fileName'], :data_type => 'zip')
        end

        binary_blob.binary = data[:attachments]
        self.status = STATUS_READY
        save!
      end

      $mw_log.info("#{log_prefix} Generation of JDR report [#{id}] [#{binary_blob.name}] succeded.")
    ensure
      @connection.close_connection!
    end

    def jdr_report_failed(error)
      $mw_log.warn("#{log_prefix} Generation of JDR report [#{id}] failed: #{error}.")
      self.status = STATUS_ERROR
      self.error_message = error
      save!
    ensure
      @connection.close_connection!
    end

    def log_prefix
      @_log_prefix ||= "EMS_#{ems_id}(Hawkular::MWM::MwJdrReport)"
    end
  end
end
