require 'json'
require 'net/http'
require 'uri'
require 'base64'
require 'nokogiri'

def get_env_variable(key)
    return (ENV[key] != nil && ENV[key] !="") ? ENV[key] : abort("Missing #{key}.")
end

$organization_name = get_env_variable('AC_AZURE_ORG_NAME')
$project_name = get_env_variable('AC_AZURE_PROJECT_NAME')
$repository = get_env_variable('AC_AZURE_REPO_NAME')
$base_url = get_env_variable('AC_AZURE_BASE_URL')
azure_api_key = get_env_variable('AC_AZURE_API_KEY')
$basic_token = "Basic #{Base64.strict_encode64(":#{azure_api_key}")}"
$json_content = "application/json"

$ac_pr_number = get_env_variable('AC_PULL_NUMBER')
detekt_file_path = get_env_variable('AC_DETEKT_FILE_PATH')
detekt_html = File.read(detekt_file_path)
$doc_detekt = Nokogiri::HTML::Document.parse(detekt_html)
ac_build_profile_id = get_env_variable('AC_BUILD_PROFILE_ID')
ac_domain_name = get_env_variable('AC_DOMAIN_NAME')
$azure_api_version = get_env_variable('AC_AZURE_API_VERSION')
$ac_build_profile_url = "https://#{ac_domain_name}/build/detail/#{ac_build_profile_id}"

def extract_total_findings()
    findings_num = $doc_detekt.at_xpath('//h2[text()="Findings"]/following-sibling::div').text[/Total: (\d[\d,]*)/, 1].gsub(',', '').to_i
    return findings_num
end

def extract_metrics_and_complexity(findings_num)
    metrics_heading = $doc_detekt.at('h2:contains("Metrics")')
    complexity_heading = $doc_detekt.at('h2:contains("Complexity Report")')
    message = "#Summary based on Detekt results run from Appcircle:"
    
    if metrics_heading || complexity_heading
        metrics_items = metrics_heading.next_element.css('li').map(&:text) || []

        message+= "\n\n ## :bar_chart: Metrics:\n"
        metrics_items.each { |item| message+= "\n- #{item}" }
      
        message+= "\n\n## :flashlight: Findings:\n"
        message+= "\n- Total: #{findings_num}"

        message+= "\n\n## :clipboard: Appcircle Detekt Build Link:\n"
        message+= "\n- #{$ac_build_profile_url}"

        return message
    else
        return "Metrics and Complexity Report headings not found."
    end
end

def add_comment_to_pr(warning_message)

    puts "Add comments to PR started"
    url = URI("#{$base_url}/#{$organization_name}/#{$project_name}/_apis/git/repositories/#{$repository}/pullRequests/#{$ac_pr_number}/threads?api-version=#{$azure_api_version}")

    https = Net::HTTP.new(url.host, url.port)
    https.use_ssl = true

    request = Net::HTTP::Post.new(url)
    request["Authorization"] = $basic_token
    request["Content-Type"] = $json_content
    
    request.body = JSON.dump({
        "comments": [
            {
            "content": warning_message
            }
        ],
    })

    response = https.request(request)

    if response.code.to_i == 200
        puts "Comment added to PR ##{$ac_pr_number} successfully."
    else
        abort "Error adding comment to PR ##{$ac_pr_number}. \nResponse message: #{response.message}"
    end
end

def change_status(status_warn_msg, status_state)

    puts "Change status of PR ##{$ac_pr_number}"
    url = URI("#{$base_url}/#{$organization_name}/#{$project_name}/_apis/git/repositories/#{$repository}/pullRequests/#{$ac_pr_number}/statuses?api-version=#{$azure_api_version}")

    https = Net::HTTP.new(url.host, url.port)
    https.use_ssl = true

    request = Net::HTTP::Post.new(url)
    request["Authorization"] = $basic_token
    request["Content-Type"] = $json_content

    request.body = JSON.dump({
        "context": {
            "genre": "",
            "name": "Success"
        },
        "state": status_state,
        "description": status_warn_msg
    })

    response = https.request(request)

    if response.code.to_i == 200
        puts "Status changed to PR ##{$ac_pr_number} successfully."
    else
        abort "Error changing status to PR ##{$ac_pr_number}. \nResponse message: #{response.message}"
    end
end

if File.exist?(detekt_file_path)
    findings_num = extract_total_findings()
    if  findings_num > 0
        puts "Finding Total: #{findings_num}"
        status_warn_msg = "Some errors were returned from the detect report for PR ##{$ac_pr_number}, the errors should be fixed."
        puts state_warn_msg
        warning_message = extract_metrics_and_complexity(findings_num)
        status_state = "failed"

        add_comment_to_pr(warning_message)
        change_status(status_warn_msg, status_state)
    else
        puts "Finding Total: #{findings_num}."
        warning_message = "PR #{$ac_pr_number} is ready to review! No warnings, No violation."
        status_state = "successed"

        add_comment_to_pr(warning_message)
        change_status(warning_message, status_state)
    end
else
    abort "Detekt results file not found for PR ##{$ac_pr_number}."
end