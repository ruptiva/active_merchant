module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class RecebeeGateway < Gateway
      self.test_url = ENV['API_SWITCHER_RECEBEE_URL']
      self.live_url = ENV['API_SWITCHER_RECEBEE_URL']

      self.supported_countries = ['BR']
      self.default_currency = 'BRL'
      self.supported_cardtypes = [:visa, :master, :elo]

      self.homepage_url = 'https://recebee.com.br/'
      self.display_name = 'Recebee Gateway'

      STANDARD_ERROR_CODE_MAPPING = {}

      def initialize(options={})
        requires!(options, :access_token)
        @access_token = options[:access_token]
        @customer_id = 123

        super
      end

      def purchase(amount, payment_type, options = {})
        p '-' *100
        p "amount: #{amount}"
        p "payment_type: #{payment_type}"
        p "options: #{options}"
        p '-' *100

        post = {}

        add_payment_type(post, payment_type)
        add_metadata(post)
        if post[:payment_type] == 'boleto'
          # estamos utilizando o credit_card.name para passar o customer_id na
          # zoop, quando o meio de pagamento é boleto
          customer_id = payment_type.name
          add_customer(post, customer_id)
          add_amount_to_boleto(post, amount)
          add_expiration_date(post)
        else
          add_credit_card(post, payment_type)
          add_amount_to_credit_card(post, amount)
          add_installments(post, options) if options[:number_installments]
        end

        commit(:post, "v1/customers/#{@customer_id}/transactions?#{post_data(post)}", {})
      end

      # def authorize(amount, payment, options={})
      #   post = {}
      #   add_payment(post, payment)
      #   add_address(post, payment, options)
      #   add_customer_data(post, options)

      #   commit('authonly', post)
      # end

      # def capture(amount, authorization, options={})
      #   commit('capture', post)
      # end

      def refund(amount, authorization, options={})
        post = {}
        commit('refund', post)
      end

      def void(authorization, options = {})
        return Response.new(false, 'Não é possível estornar uma transação sem uma prévia autorização.') if authorization.nil?

        post = {}
        commit(:post, "v1/customers/#{@customer_id}/transactions/#{transaction_id}/refund", post)
      end

      # def verify(credit_card, options={})
      #   MultiResponse.run(:use_first_response) do |r|
      #     r.process { authorize(100, credit_card, options) }
      #     r.process(:ignore_result) { void(r.authorization, options) }
      #   end
      # end

      def supports_scrubbing?
        true
      end

      def scrub(transcript)
        #byebug # talvez devesse filtrar dados sensíveis que passam por aqui
        transcript
      end

      private

      def add_amount_to_credit_card(post, amount)
        post[:source] = {} unless post[:source]

        post[:source][:amount] = amount
        post[:source][:currency] = 'BRL'
      end

      def add_amount_to_boleto(post, amount)
        post[:amount] = amount
        post[:currency] = 'BRL'
      end

      def add_payment_type(post, payment_type)
        credit_card = payment_type
        if credit_card.number == '5534238414271981'
          post[:payment_type] = 'boleto'
        else
          post[:payment_type] = 'credit'
        end
      end

      def add_customer(post, customer)
        post[:customer] = customer
      end

      def add_expiration_date(post)
        post[:payment_method] = {} unless post[:payment_method]

        #byebug # essa regra de negócio, do boleto vencer em 3 dias corridos, talvez não devesse estar aqui (?)
        post[:payment_method][:expiration_date] = 3.days.from_now.to_date.to_s
      end

      def add_credit_card(post, credit_card)
        post[:source] = {} unless post[:source]
        post[:source][:card] = {} unless post[:source][:card]

        post[:source][:usage] = 'single_use'
        post[:source][:type] = 'card'
        post[:source][:card][:holder_name] = credit_card.name
        post[:source][:card][:expiration_month] = "#{credit_card.month}"
        post[:source][:card][:expiration_year] = "#{credit_card.year}"
        post[:source][:card][:card_number] = credit_card.number
        post[:source][:card][:security_code] = credit_card.verification_value
      end

      def add_installments(post, options)
        post[:installment_plan] = {} unless post[:installment_plan]

        post[:installment_plan][:mode] = 'interest_free'#byebug # era pra ser hardcoded essa opção?
        post[:installment_plan][:number_installments] = options[:number_installments]
      end

      def add_metadata(post)
        post[:description] = 'Spree'
      end

      # def add_customer_data(post, options)
      # end

      # def add_address(post, creditcard, options)
      # end

      # def add_payment(post, payment)
      # end

      def commit(method, url, parameters, options = {})
        response = api_request(method, url, parameters, options)

        Response.new(
          success_from(response),
          message_from(response),
          response,
          authorization: authorization_from(response),
          test: test?,
          error_code: error_code_from(response)
        )
      end

      def response_error(raw_response)
        parse(raw_response)
      rescue JSON::ParserError
        json_error(raw_response)
      end

      def json_error(raw_response)
        msg = 'Resposta inválida retornada pela API do Switcher Recebee.'
        msg += "  (A resposta retornada pela API foi #{raw_response.inspect})"
        {
          'errors' => [{
            'message' => msg
          }]
        }
      end

      def success_from(response)
        # Zoop returns, on 201 response:
        # 'succeeded' status to credit card transactions 
        # 'pending' status to boleto transactions 
        success_purchase = response.key?('status') && response['status'].in?(['succeeded', 'pending'])
        success_purchase
      end

      def message_from(response)
        if success_from(response)
          'Transação aprovada'
        else
          'Houve um erro ao criar a transação'
        end
      end

      def authorization_from(response)
        # este método aparentemente precisa retornar o ID da transação
        response['id'] if success_from(response)
      end

      def error_code_from(response)
        unless success_from(response)
          STANDARD_ERROR_CODE_MAPPING['processing_error']
        end
      end

      def api_request(method, endpoint, parameters = nil, options = {})
        raw_response = response = nil
        begin
          raw_response = ssl_request(method, self.live_url + endpoint, post_data(parameters), headers(options))
          response = parse(raw_response)
        rescue ResponseError => e
          raw_response = e.response.body
          response = response_error(raw_response)
        rescue JSON::ParserError
          response = json_error(raw_response)
        end
        response
      end

      def parse(body)
        JSON.parse(body)
      end

      def post_data(params)
        return nil unless params

        params.map do |key, value|
          next if value != false && value.blank?

          if value.is_a?(Hash)
            h = {}
            value.each do |k, v|
              h["#{key}[#{k}]"] = v unless v.blank?
            end
            post_data(h)
          elsif value.is_a?(Array)
            value.map { |v| "#{key}[]=#{CGI.escape(v.to_s)}" }.join('&')
          else
            "#{key}=#{CGI.escape(value.to_s)}"
          end
        end.compact.join('&')
      end

      def headers(options)
        headers = {
          'Content-Type' => 'application/json',
          # 'User-Agent' => "ActiveMerchantBindings/#{ActiveMerchant::VERSION}",
          'Authorization' => "Bearer #{@access_token}"
        }

        headers
      end

      def test?
        live_url.include?('homolog')
      end
    end
  end
end
