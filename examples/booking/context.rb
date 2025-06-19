# frozen_string_literal: true

# Airline-specific context for managing passenger information
# across agent handoffs and tool executions
class AirlineContext < Agents::Context
  attr_accessor :passenger_name, :confirmation_number, :seat_number, :flight_number

  def initialize
    super
    @passenger_name = nil
    @confirmation_number = nil
    @seat_number = nil
    @flight_number = nil
  end

  # Generate a random flight number for seat bookings
  def assign_flight_number!
    @flight_number = "FLT-#{rand(100..999)}"
    self[:flight_number] = @flight_number
  end

  # Check if all required booking info is present
  def booking_complete?
    @passenger_name && @confirmation_number && @seat_number && @flight_number
  end

  # Get booking summary
  def booking_summary
    return "No booking information available" unless booking_complete?

    "Flight #{@flight_number}: #{@passenger_name} (#{@confirmation_number}) - Seat #{@seat_number}"
  end
end
