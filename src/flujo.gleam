// Flujo's public module is deliberately small. Business behaviour lives in
// flujo/domain and has no infrastructure dependencies.
import flujo/application/server

pub const version = "0.1.0"

pub fn main() {
  server.main()
}
