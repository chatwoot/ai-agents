# frozen_string_literal: true

module CSDemo
  module Airline
    MOCK_ITINERARIES = {
      disrupted: {
        name: "Paris to New York to Austin",
        passenger_name: "Morgan Lee",
        confirmation_number: "IR-D204",
        seat_number: "14C",
        baggage_tag: "BG20488",
        segments: [
          {
            flight_number: "PA441",
            origin: "Paris (CDG)",
            destination: "New York (JFK)",
            departure: "2024-12-09 14:10",
            arrival: "2024-12-09 17:40",
            status: "Delayed 5 hours due to weather, expected departure 19:55",
            gate: "B18"
          },
          {
            flight_number: "NY802",
            origin: "New York (JFK)",
            destination: "Austin (AUS)",
            departure: "2024-12-09 19:10",
            arrival: "2024-12-09 22:35",
            status: "Connection missed because of first leg delay",
            gate: "C7"
          }
        ],
        rebook_options: [
          {
            flight_number: "NY950",
            origin: "New York (JFK)",
            destination: "Austin (AUS)",
            departure: "2024-12-10 09:45",
            arrival: "2024-12-10 12:30",
            seat: "2A (front row)",
            note: "Partner flight secured with auto-reaccommodation for disrupted travelers"
          },
          {
            flight_number: "NY982",
            origin: "New York (JFK)",
            destination: "Austin (AUS)",
            departure: "2024-12-10 13:20",
            arrival: "2024-12-10 16:05",
            seat: "3C",
            note: "Backup option if the morning flight is full"
          }
        ],
        vouchers: {
          hotel: "Overnight hotel covered up to $180 near JFK Terminal 5 partner hotel",
          meal: "$60 meal credit for the delay",
          ground: "$40 ground transport credit to the hotel"
        }
      },
      on_time: {
        name: "On-time commuter flight",
        passenger_name: "Taylor Lee",
        confirmation_number: "LL0EZ6",
        seat_number: "23A",
        baggage_tag: "BG55678",
        segments: [
          {
            flight_number: "FLT-123",
            origin: "San Francisco (SFO)",
            destination: "Los Angeles (LAX)",
            departure: "2024-12-09 16:10",
            arrival: "2024-12-09 17:35",
            status: "On time and operating as scheduled",
            gate: "A10"
          }
        ],
        rebook_options: [],
        vouchers: {}
      }
    }.freeze

    module_function

    def initial_state
      {
        passenger_name: nil,
        confirmation_number: nil,
        seat_number: nil,
        flight_number: nil,
        account_number: nil,
        itinerary: nil,
        baggage_claim_id: nil,
        compensation_case_id: nil,
        scenario: nil,
        vouchers: nil,
        special_service_note: nil,
        origin: nil,
        destination: nil,
        show_seat_map: false
      }
    end

    def apply_itinerary_defaults(state, scenario_key: nil)
      target_key = (scenario_key || state[:scenario] || :disrupted).to_sym
      data = MOCK_ITINERARIES.fetch(target_key, MOCK_ITINERARIES[:disrupted])
      segments = deep_copy(data[:segments])

      state[:scenario] = target_key
      state[:passenger_name] ||= data[:passenger_name]
      state[:confirmation_number] ||= data[:confirmation_number]
      state[:flight_number] ||= segments.first&.fetch(:flight_number, nil)
      state[:seat_number] ||= data[:seat_number]
      state[:itinerary] ||= segments
      state[:origin] ||= segments.first&.fetch(:origin, nil)
      state[:destination] ||= segments.last&.fetch(:destination, nil)
      state
    end

    def active_itinerary(state)
      scenario = state[:scenario]&.to_sym
      return [scenario, MOCK_ITINERARIES[scenario]] if scenario && MOCK_ITINERARIES[scenario]

      match = get_itinerary_for_flight(state[:flight_number])
      if match
        state[:scenario] = match.first
        return match
      end

      state[:scenario] = :disrupted
      [:disrupted, MOCK_ITINERARIES[:disrupted]]
    end

    def get_itinerary_for_flight(flight_number)
      return nil if flight_number.nil? || flight_number.to_s.empty?

      target = flight_number.to_s.downcase
      MOCK_ITINERARIES.each do |key, itinerary|
        all_segments = itinerary[:segments] + itinerary[:rebook_options]
        return [key, itinerary] if all_segments.any? { |segment| segment[:flight_number].downcase == target }
      end
      nil
    end

    def public_context(state)
      state.each_with_object({}) do |(key, value), public_state|
        next if %i[itinerary baggage_claim_id compensation_case_id scenario show_seat_map].include?(key)
        next if key == :vouchers && (value.nil? || value.empty?)

        public_state[key] = value
      end
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end
  end
end
