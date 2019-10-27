require 'active_support/core_ext/string/inflections'
require 'cocoapods/xcode/framework_paths'

module Pod
  class Installer
    class UserProjectIntegrator
      # This class is responsible for integrating the library generated by a
      # {TargetDefinition} with its destination project.
      #
      class TargetIntegrator
        autoload :XCConfigIntegrator, 'cocoapods/installer/user_project_integrator/target_integrator/xcconfig_integrator'

        # @return [String] the string to use as prefix for every build phase added to the user project
        #
        BUILD_PHASE_PREFIX = '[CP] '.freeze

        # @return [String] the string to use as prefix for every build phase declared by the user within a podfile
        #         or podspec.
        #
        USER_BUILD_PHASE_PREFIX = '[CP-User] '.freeze

        # @return [String] the name of the check manifest phase
        #
        CHECK_MANIFEST_PHASE_NAME = 'Check Pods Manifest.lock'.freeze

        # @return [Array<Symbol>] the symbol types, which require that the pod
        # frameworks are embedded in the output directory / product bundle.
        #
        # @note This does not include :app_extension or :watch_extension because
        # these types must have their frameworks embedded in their host targets.
        # For messages extensions, this only applies if it's embedded in a messages
        # application.
        #
        EMBED_FRAMEWORK_TARGET_TYPES = [:application, :unit_test_bundle, :ui_test_bundle, :watch2_extension, :messages_application].freeze

        # @return [String] the name of the embed frameworks phase
        #
        EMBED_FRAMEWORK_PHASE_NAME = 'Embed Pods Frameworks'.freeze

        # @return [String] the name of the embed frameworks phase
        #
        EMBED_XCFRAMEWORK_PHASE_NAME = 'Embed Pods XCFrameworks'.freeze

        # @return [String] the name of the copy resources phase
        #
        COPY_PODS_RESOURCES_PHASE_NAME = 'Copy Pods Resources'.freeze

        # @return [Integer] the maximum number of input and output paths to use for a script phase
        #
        MAX_INPUT_OUTPUT_PATHS = 1000

        # @return [AggregateTarget] the target that should be integrated.
        #
        attr_reader :target

        # @return [Boolean] whether to use input/output paths for build phase scripts
        #
        attr_reader :use_input_output_paths
        alias use_input_output_paths? use_input_output_paths

        # Init a new TargetIntegrator
        #
        # @param  [AggregateTarget] target @see #target
        # @param  [Boolean] use_input_output_paths @see #use_input_output_paths
        #
        def initialize(target, use_input_output_paths: true)
          @target = target
          @use_input_output_paths = use_input_output_paths
        end

        # @private
        #
        XCFileListConfigKey = Struct.new(:file_list_path, :file_list_relative_path)

        class << self
          # @param  [Xcodeproj::Project::Object::AbstractObject] object
          #
          # @return [Boolean] Whether input & output paths for the given object
          #         should be stored in a file list file.
          #
          def input_output_paths_use_filelist?(object)
            object.project.object_version.to_i >= 50
          end

          # Sets the input & output paths for the given script build phase.
          #
          # @param  [Xcodeproj::Project::Object::PBXShellScriptBuildPhase] phase
          #         The phase to set input & output paths on.
          #
          # @param  [Hash] input_paths_by_config
          #
          # @return [Void]
          def set_input_output_paths(phase, input_paths_by_config, output_paths_by_config)
            if input_output_paths_use_filelist?(phase)
              [input_paths_by_config, output_paths_by_config].each do |hash|
                hash.each do |file_list, files|
                  generator = Generator::FileList.new(files)
                  Xcode::PodsProjectGenerator::TargetInstallerHelper.update_changed_file(generator, file_list.file_list_path)
                end
              end

              phase.input_paths = nil
              phase.output_paths = nil
              phase.input_file_list_paths = input_paths_by_config.each_key.map(&:file_list_relative_path).uniq
              phase.output_file_list_paths = output_paths_by_config.each_key.map(&:file_list_relative_path).uniq
            else
              input_paths = input_paths_by_config.values.flatten(1).uniq
              output_paths = output_paths_by_config.values.flatten(1).uniq
              TargetIntegrator.validate_input_output_path_limit(input_paths, output_paths)

              phase.input_paths = input_paths
              phase.output_paths = output_paths
              phase.input_file_list_paths = nil
              phase.output_file_list_paths = nil
            end
          end

          # Adds a shell script build phase responsible to copy (embed) the frameworks
          # generated by the TargetDefinition to the bundle of the product of the
          # targets.
          #
          # @param [PBXNativeTarget] native_target
          #        The native target to add the script phase into.
          #
          # @param [String] script_path
          #        The script path to execute as part of this script phase.
          #
          # @param [Hash<Array, String>] input_paths_by_config
          #        The input paths (if any) to include for this script phase.
          #
          # @param [Hash<Array, String>] output_paths_by_config
          #        The output paths (if any) to include for this script phase.
          #
          # @return [void]
          #
          def create_or_update_embed_frameworks_script_phase_to_target(native_target, script_path, input_paths_by_config = {}, output_paths_by_config = {})
            phase = TargetIntegrator.create_or_update_shell_script_build_phase(native_target, BUILD_PHASE_PREFIX + EMBED_FRAMEWORK_PHASE_NAME)
            phase.shell_script = %("#{script_path}"\n)
            TargetIntegrator.set_input_output_paths(phase, input_paths_by_config, output_paths_by_config)
          end

          # Adds a shell script build phase responsible to copy (embed) the xcframeworks
          # generated by the TargetDefinition to the bundle of the product of the
          # targets.
          #
          # @param [PBXNativeTarget] native_target
          #        The native target to add the script phase into.
          #
          # @param [String] script_path
          #        The script path to execute as part of this script phase.
          #
          # @param [Hash<Array, String>] input_paths_by_config
          #        The input paths (if any) to include for this script phase.
          #
          # @param [Hash<Array, String>] output_paths_by_config
          #        The output paths (if any) to include for this script phase.
          #
          # @return [void]
          #
          def create_or_update_embed_xcframeworks_script_phase_to_target(native_target, script_path, input_paths_by_config = {}, output_paths_by_config = {})
            puts "create_or_update_embed_xcframeworks_script_phase_to_target script_path = #{script_path}"
            phase = TargetIntegrator.create_or_update_shell_script_build_phase(native_target, BUILD_PHASE_PREFIX + EMBED_XCFRAMEWORK_PHASE_NAME)
            phase.shell_script = %("#{script_path}"\n)
            reorder_script_phase(native_target, phase, :before_compile)
            TargetIntegrator.set_input_output_paths(phase, input_paths_by_config, output_paths_by_config)
          end

          # Delete a 'Embed Pods Frameworks' Copy Files Build Phase if present
          #
          # @param [PBXNativeTarget] native_target
          #        The native target to remove the script phase from.
          #
          def remove_embed_frameworks_script_phase_from_target(native_target)
            remove_script_phase_from_target(native_target, EMBED_FRAMEWORK_PHASE_NAME)
          end

          # Delete a 'Embed Pods Frameworks' Copy Files Build Phase if present
          #
          # @param [PBXNativeTarget] native_target
          #        The native target to remove the script phase from.
          #
          def remove_embed_xcframeworks_script_phase_from_target(native_target)
            remove_script_phase_from_target(native_target, EMBED_XCFRAMEWORK_PHASE_NAME)
          end

          def remove_script_phase_from_target(native_target, phase_name)
            build_phase = native_target.shell_script_build_phases.find { |bp| bp.name && bp.name.end_with?(phase_name) }
            return unless build_phase.present?
            native_target.build_phases.delete(build_phase)
          end

          # Adds a shell script build phase responsible to copy the resources
          # generated by the TargetDefinition to the bundle of the product of the
          # targets.
          #
          # @param [PBXNativeTarget] native_target
          #        The native target to add the script phase into.
          #
          # @param [String] script_path
          #        The script path to execute as part of this script phase.
          #
          # @param [Hash<Array, String>] input_paths_by_config
          #        The input paths (if any) to include for this script phase.
          #
          # @param [Hash<Array, String>] output_paths_by_config
          #        The output paths (if any) to include for this script phase.
          #
          # @return [void]
          #
          def create_or_update_copy_resources_script_phase_to_target(native_target, script_path, input_paths_by_config = {}, output_paths_by_config = {})
            phase_name = COPY_PODS_RESOURCES_PHASE_NAME
            phase = TargetIntegrator.create_or_update_shell_script_build_phase(native_target, BUILD_PHASE_PREFIX + phase_name)
            phase.shell_script = %("#{script_path}"\n)
            TargetIntegrator.set_input_output_paths(phase, input_paths_by_config, output_paths_by_config)
          end

          # Delete a 'Copy Pods Resources' script phase if present
          #
          # @param [PBXNativeTarget] native_target
          #        The native target to remove the script phase from.
          #
          def remove_copy_resources_script_phase_from_target(native_target)
            build_phase = native_target.shell_script_build_phases.find { |bp| bp.name && bp.name.end_with?(COPY_PODS_RESOURCES_PHASE_NAME) }
            return unless build_phase.present?
            native_target.build_phases.delete(build_phase)
          end

          # Creates or update a shell script build phase for the given target.
          #
          # @param [PBXNativeTarget] native_target
          #        The native target to add the script phase into.
          #
          # @param [String] script_phase_name
          #        The name of the script phase to use.
          #
          # @param [String] show_env_vars_in_log
          #        The value to set for show environment variables in the log during execution of this script phase or
          #        `nil` for not setting the value at all.
          #
          # @return [void]
          #
          def create_or_update_shell_script_build_phase(native_target, script_phase_name, show_env_vars_in_log = '0')
            build_phases = native_target.build_phases.grep(Xcodeproj::Project::Object::PBXShellScriptBuildPhase)
            build_phases.find { |phase| phase.name && phase.name.end_with?(script_phase_name) }.tap { |p| p.name = script_phase_name if p } ||
              native_target.project.new(Xcodeproj::Project::Object::PBXShellScriptBuildPhase).tap do |phase|
                UI.message("Adding Build Phase '#{script_phase_name}' to project.") do
                  phase.name = script_phase_name
                  unless show_env_vars_in_log.nil?
                    phase.show_env_vars_in_log = show_env_vars_in_log
                  end
                  native_target.build_phases << phase
                end
              end
          end

          # Updates all target script phases for the current target, including creating or updating, deleting
          # and re-ordering.
          #
          # @return [void]
          #
          def create_or_update_user_script_phases(script_phases, native_target)
            script_phase_names = script_phases.map { |k| k[:name] }
            # Delete script phases no longer present in the target.
            native_target_script_phases = native_target.shell_script_build_phases.select { |bp| !bp.name.nil? && bp.name.start_with?(USER_BUILD_PHASE_PREFIX) }
            native_target_script_phases.each do |script_phase|
              script_phase_name_without_prefix = script_phase.name.sub(USER_BUILD_PHASE_PREFIX, '')
              unless script_phase_names.include?(script_phase_name_without_prefix)
                native_target.build_phases.delete(script_phase)
              end
            end
            # Create or update the ones that are expected to be.
            script_phases.each do |script_phase|
              name_with_prefix = USER_BUILD_PHASE_PREFIX + script_phase[:name]
              phase = TargetIntegrator.create_or_update_shell_script_build_phase(native_target, name_with_prefix, nil)
              phase.shell_script = script_phase[:script]
              phase.shell_path = script_phase[:shell_path] || '/bin/sh'
              phase.input_paths = script_phase[:input_files]
              phase.output_paths = script_phase[:output_files]
              phase.input_file_list_paths = script_phase[:input_file_lists]
              phase.output_file_list_paths = script_phase[:output_file_lists]
              phase.dependency_file = script_phase[:dependency_file]
              # At least with Xcode 10 `showEnvVarsInLog` is *NOT* set to any value even if it's checked and it only
              # gets set to '0' if the user has explicitly disabled this.
              if (show_env_vars_in_log = script_phase.fetch(:show_env_vars_in_log, '1')) == '0'
                phase.show_env_vars_in_log = show_env_vars_in_log
              end

              execution_position = script_phase[:execution_position]
              reorder_script_phase(native_target, phase, execution_position)
            end
          end

          def reorder_script_phase(native_target, script_phase, execution_position)
            return if execution_position == :any
            compile_build_phase_index = native_target.build_phases.index do |bp|
              bp.is_a?(Xcodeproj::Project::Object::PBXSourcesBuildPhase)
            end
            unless compile_build_phase_index.nil?
              script_phase_index = native_target.build_phases.index do |bp|
                bp.is_a?(Xcodeproj::Project::Object::PBXShellScriptBuildPhase) && !bp.name.nil? && bp.name == script_phase.name
              end
              if (execution_position == :before_compile && script_phase_index > compile_build_phase_index) ||
                (execution_position == :after_compile && script_phase_index < compile_build_phase_index)
                native_target.build_phases.move_from(script_phase_index, compile_build_phase_index)
              end
            end
          end

          # Script phases can have a limited number of input and output paths due to each one being exported to `env`.
          # A large number can cause a build failure because of limitations in `env`. See issue
          # https://github.com/CocoaPods/CocoaPods/issues/7362.
          #
          # @param [Array<String>] input_paths
          #        The input paths to trim.
          #
          # @param [Array<String>] output_paths
          #        The output paths to trim.
          #
          # @return [void]
          #
          def validate_input_output_path_limit(input_paths, output_paths)
            if (input_paths.count + output_paths.count) > MAX_INPUT_OUTPUT_PATHS
              input_paths.clear
              output_paths.clear
            end
          end

          # Returns an extension in the target that corresponds to the
          # resource's input extension.
          #
          # @param [String] input_extension
          #        The input extension to map to.
          #
          # @return [String] The output extension.
          #
          def output_extension_for_resource(input_extension)
            case input_extension
            when '.storyboard'        then '.storyboardc'
            when '.xib'               then '.nib'
            when '.framework'         then '.framework'
            when '.xcdatamodel'       then '.mom'
            when '.xcdatamodeld'      then '.momd'
            when '.xcmappingmodel'    then '.cdm'
            when '.xcassets'          then '.car'
            else                      input_extension
            end
          end

          # Returns the resource output paths for all given input paths.
          #
          # @param [Array<String>] resource_input_paths
          #        The input paths to map to.
          #
          # @return [Array<String>] The resource output paths.
          #
          def resource_output_paths(resource_input_paths)
            resource_input_paths.map do |resource_input_path|
              base_path = '${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}'
              extname = File.extname(resource_input_path)
              basename = extname == '.xcassets' ? 'Assets' : File.basename(resource_input_path)
              output_extension = TargetIntegrator.output_extension_for_resource(extname)
              File.join(base_path, File.basename(basename, extname) + output_extension)
            end.uniq
          end

          # Returns the framework output paths for the given input paths
          #
          # @param  [Array<Xcode::FrameworkPaths>] framework_input_paths
          #         The framework input paths to map to output paths.
          #
          # @return [Array<String>] The framework output paths
          #
          def framework_output_paths(framework_input_paths)
            framework_input_paths.flat_map do |framework_path|
              framework_output_path = "${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/#{File.basename(framework_path.source_path)}"
              dsym_output_path = if (dsym_input_path = framework_path.dsym_path)
                                   "${DWARF_DSYM_FOLDER_PATH}/#{File.basename(dsym_input_path)}"
                                 end
              bcsymbol_output_paths = unless framework_path.bcsymbolmap_paths.nil?
                                        framework_path.bcsymbolmap_paths.map do |bcsymbolmap_path|
                                          "${BUILT_PRODUCTS_DIR}/#{File.basename(bcsymbolmap_path)}"
                                        end
                                      end
              [framework_output_path, dsym_output_path, *bcsymbol_output_paths]
            end.compact.uniq
          end
        end

        # Integrates the user project targets. Only the targets that do **not**
        # already have the Pods library in their frameworks build phase are
        # processed.
        #
        # @return [void]
        #
        def integrate!
          UI.section(integration_message) do
            XCConfigIntegrator.integrate(target, native_targets)

            add_pods_library
            add_embed_frameworks_script_phase
            add_embed_xcframeworks_script_phase
            remove_embed_frameworks_script_phase_from_embedded_targets
            add_copy_resources_script_phase
            add_check_manifest_lock_script_phase
            add_user_script_phases
          end
        end

        # @return [String] a string representation suitable for debugging.
        #
        def inspect
          "#<#{self.class} for target `#{target.label}'>"
        end

        private

        # @!group Integration steps
        #---------------------------------------------------------------------#

        # Adds spec product reference to the frameworks build phase of the
        # {TargetDefinition} integration libraries. Adds a file reference to
        # the frameworks group of the project and adds it to the frameworks
        # build phase of the targets.
        #
        # @return [void]
        #
        def add_pods_library
          frameworks = user_project.frameworks_group
          native_targets.each do |native_target|
            build_phase = native_target.frameworks_build_phase
            product_name = target.product_name

            # Delete previously integrated references.
            product_build_files = build_phase.files.select do |build_file|
              build_file.display_name =~ Pod::Deintegrator::FRAMEWORK_NAMES
            end

            product_build_files.each do |product_file|
              next unless product_name != product_file.display_name
              UI.message("Removing old product reference `#{product_file.display_name}` from project.")
              frameworks.remove_reference(product_file.file_ref)
              build_phase.remove_build_file(product_file)
            end

            # Find or create and add a reference for the current product type
            new_product_ref = frameworks.files.find { |f| f.path == product_name } ||
                frameworks.new_product_ref_for_target(target.product_basename, target.product_type)
            build_phase.build_file(new_product_ref) ||
                build_phase.add_file_reference(new_product_ref, true)
          end
        end

        # Find or create a 'Copy Pods Resources' build phase
        #
        # @return [void]
        #
        def add_copy_resources_script_phase
          unless target.includes_resources?
            native_targets.each do |native_target|
              TargetIntegrator.remove_copy_resources_script_phase_from_target(native_target)
            end
            return
          end

          script_path = target.copy_resources_script_relative_path
          input_paths_by_config = {}
          output_paths_by_config = {}
          if use_input_output_paths
            target.resource_paths_by_config.each do |config, resource_paths|
              input_paths_key = XCFileListConfigKey.new(target.copy_resources_script_input_files_path(config), target.copy_resources_script_input_files_relative_path)
              input_paths_by_config[input_paths_key] = [script_path] + resource_paths

              output_paths_key = XCFileListConfigKey.new(target.copy_resources_script_output_files_path(config), target.copy_resources_script_output_files_relative_path)
              output_paths_by_config[output_paths_key] = TargetIntegrator.resource_output_paths(resource_paths)
            end
          end

          native_targets.each do |native_target|
            # Static library targets cannot include resources. Skip this phase from being added instead.
            next if native_target.symbol_type == :static_library
            TargetIntegrator.create_or_update_copy_resources_script_phase_to_target(native_target, script_path, input_paths_by_config, output_paths_by_config)
          end
        end

        # Removes the embed frameworks build phase from embedded targets
        #
        # @note Older versions of CocoaPods would add this build phase to embedded
        #       targets. They should be removed on upgrade because embedded targets
        #       will have their frameworks embedded in their host targets.
        #
        def remove_embed_frameworks_script_phase_from_embedded_targets
          return unless target.requires_host_target?
          native_targets.each do |native_target|
            if AggregateTarget::EMBED_FRAMEWORKS_IN_HOST_TARGET_TYPES.include? native_target.symbol_type
              TargetIntegrator.remove_embed_frameworks_script_phase_from_target(native_target)
            end
          end
        end

        # Find or create a 'Embed Pods Frameworks' Copy Files Build Phase
        #
        # @return [void]
        #
        def add_embed_frameworks_script_phase
          unless target.includes_frameworks?
            native_targets_to_embed_in.each do |native_target|
              TargetIntegrator.remove_embed_frameworks_script_phase_from_target(native_target)
            end
            return
          end

          script_path = target.embed_frameworks_script_relative_path
          input_paths_by_config = {}
          output_paths_by_config = {}
          if use_input_output_paths?
            target.framework_paths_by_config.each do |config, framework_paths|
              input_paths_key = XCFileListConfigKey.new(target.embed_frameworks_script_input_files_path(config), target.embed_frameworks_script_input_files_relative_path)
              input_paths = input_paths_by_config[input_paths_key] = [script_path]
              framework_paths.each do |path|
                input_paths.concat(path.all_paths)
              end

              output_paths_key = XCFileListConfigKey.new(target.embed_frameworks_script_output_files_path(config), target.embed_frameworks_script_output_files_relative_path)
              output_paths_by_config[output_paths_key] = TargetIntegrator.framework_output_paths(framework_paths)
            end
          end

          native_targets_to_embed_in.each do |native_target|
            TargetIntegrator.create_or_update_embed_frameworks_script_phase_to_target(native_target, script_path, input_paths_by_config, output_paths_by_config)
          end
        end

        # Find or create a 'Embed Pods XCFrameworks' Copy Files Build Phase
        #
        # @return [void]
        #
        def add_embed_xcframeworks_script_phase
          unless target.includes_xcframeworks?
            native_targets_to_embed_in.each do |native_target|
              TargetIntegrator.remove_embed_xcframeworks_script_phase_from_target(native_target)
            end
            return
          end

          script_path = target.embed_xcframeworks_script_relative_path
          input_paths_by_config = {}
          output_paths_by_config = {}
          native_targets_to_embed_in.each do |native_target|
            TargetIntegrator.create_or_update_embed_xcframeworks_script_phase_to_target(native_target, script_path, input_paths_by_config, output_paths_by_config)
          end
        end

        # Updates all target script phases for the current target, including creating or updating, deleting
        # and re-ordering.
        #
        # @return [void]
        #
        def add_user_script_phases
          native_targets.each do |native_target|
            TargetIntegrator.create_or_update_user_script_phases(target.target_definition.script_phases, native_target)
          end
        end

        # Adds a shell script build phase responsible for checking if the Pods
        # locked in the Pods/Manifest.lock file are in sync with the Pods defined
        # in the Podfile.lock.
        #
        # @note   The build phase is appended to the front because to fail
        #         fast.
        #
        # @return [void]
        #
        def add_check_manifest_lock_script_phase
          phase_name = CHECK_MANIFEST_PHASE_NAME
          native_targets.each do |native_target|
            phase = TargetIntegrator.create_or_update_shell_script_build_phase(native_target, BUILD_PHASE_PREFIX + phase_name)
            native_target.build_phases.unshift(phase).uniq! unless native_target.build_phases.first == phase
            phase.shell_script = <<-SH.strip_heredoc
              diff "${PODS_PODFILE_DIR_PATH}/Podfile.lock" "${PODS_ROOT}/Manifest.lock" > /dev/null
              if [ $? != 0 ] ; then
                  # print error to STDERR
                  echo "error: The sandbox is not in sync with the Podfile.lock. Run 'pod install' or update your CocoaPods installation." >&2
                  exit 1
              fi
              # This output is used by Xcode 'outputs' to avoid re-running this script phase.
              echo "SUCCESS" > "${SCRIPT_OUTPUT_FILE_0}"
            SH
            phase.input_paths = %w(${PODS_PODFILE_DIR_PATH}/Podfile.lock ${PODS_ROOT}/Manifest.lock)
            phase.output_paths = [target.check_manifest_lock_script_output_file_path]
          end
        end

        private

        # @!group Private Helpers
        #---------------------------------------------------------------------#

        # @return [Array<PBXNativeTarget>] The list of all the targets that
        #         match the given target.
        #
        def native_targets
          @native_targets ||= target.user_targets
        end

        # @return [Array<PBXNativeTarget>] The list of all the targets that
        #         require that the pod frameworks are embedded in the output
        #         directory / product bundle.
        #
        def native_targets_to_embed_in
          return [] if target.requires_host_target?
          native_targets.select do |target|
            EMBED_FRAMEWORK_TARGET_TYPES.include?(target.symbol_type)
          end
        end

        # Read the project from the disk to ensure that it is up to date as
        # other TargetIntegrators might have modified it.
        #
        # @return [Project]
        #
        def user_project
          target.user_project
        end

        # @return [Specification::Consumer] the consumer for the specifications.
        #
        def spec_consumers
          @spec_consumers ||= target.pod_targets.map(&:file_accessors).flatten.map(&:spec_consumer)
        end

        # @return [String] the message that should be displayed for the target
        #         integration.
        #
        def integration_message
          "Integrating target `#{target.name}` " \
            "(#{UI.path target.user_project_path} project)"
        end
      end
    end
  end
end
