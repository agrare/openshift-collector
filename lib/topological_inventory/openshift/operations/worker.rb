require "manageiq-messaging"
require "topological_inventory/openshift/logging"
require "topological_inventory/openshift/operations/core/service_catalog_client"
require "topological_inventory/openshift/operations/core/service_offering_retriever"
require "topological_inventory/openshift/operations/core/service_plan_retriever"
require "topological_inventory/openshift/operations/core/source_retriever"
require "topological_inventory-api-client"

module TopologicalInventory
  module Openshift
    module Operations
      class Worker
        include Logging

        def initialize(messaging_client_opts = {})
          self.api_client            = TopologicalInventoryApiClient::DefaultApi.new
          self.messaging_client_opts = default_messaging_opts.merge(messaging_client_opts)
        end

        def run
          # Open a connection to the messaging service
          self.client = ManageIQ::Messaging::Client.open(messaging_client_opts)

          logger.info("Topological Inventory Openshift Operations worker started...")

          client.subscribe_messages(queue_opts.merge(:max_bytes => 500000)) do |messages|
            messages.each { |msg| process_message(client, msg) }
          end
        ensure
          client&.close
        end

        def stop
          client&.close
          self.client = nil
        end

        private

        attr_accessor :messaging_client_opts, :client, :api_client

        def process_message(_client, msg)
          logger.info("Processing #{msg.message} with msg: #{msg.payload}")
          #TODO: Move to separate module later when more message types are expected aside from just ordering
          order_service(msg.payload)
        rescue => e
          logger.error(e.message)
          logger.error(e.backtrace.join("\n"))
          nil
        end

        def order_service(payload)
          service_plan_id = payload["service_plan_id"].to_s
          task_id         = payload["task_id"].to_s
          order_params    = payload["order_params"]

          service_plan = Core::ServicePlanRetriever.new(service_plan_id).process
          source = Core::SourceRetriever.new(service_plan.source_id).process
          service_offering = Core::ServiceOfferingRetriever.new(service_plan.service_offering_id).process

          catalog_client = Core::ServiceCatalogClient.new(source.id)
          parsed_response = catalog_client.order_service_plan(service_plan.name, service_offering.name, order_params)

          context = {
            :service_instance => {
              :source_id  => source.id,
              :source_ref => parsed_response['metadata']['selfLink']
            }
          }

          task = TopologicalInventoryApiClient::Task.new("status" => "completed", "context" => context)
          api_client.update_task(task_id, task)
        end

        def queue_opts
          {
            :service => "platform.topological-inventory.operations-openshift",
          }
        end

        def default_messaging_opts
          {
            :protocol   => :Kafka,
            :client_ref => "openshift-operations-worker",
            :group_ref  => "openshift-operations-worker",
          }
        end
      end
    end
  end
end
