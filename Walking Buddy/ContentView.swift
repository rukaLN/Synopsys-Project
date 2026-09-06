import SwiftUI

struct ContentView: View {
    @StateObject private var healthManager = HealthKitManager()
    
    var body: some View {
        ScrollView {
            VStack(spacing: 35) {
                Text("Mobility Monitor")
                    .font(.system(.title, design: .rounded))
                    .bold()
                
                VStack(spacing: 15) {
                    Text("Walking Status")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text(healthManager.isTracking ? "Monitoring Live" : "Not Tracking")
                        .font(.title2)
                        .bold()
                        .foregroundColor(healthManager.isTracking ? .green : .orange)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(16)

                Text(healthManager.monitoringMessage)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                
                Grid(alignment: .leading, horizontalSpacing: 40, verticalSpacing: 25) {
                    GridRow {
                        Text("Live Speed:")
                            .font(.title3).bold()
                        Text(healthManager.currentPaceStatus)
                            .font(.title3).foregroundColor(.blue)
                    }
                    GridRow {
                        Text("Cadence:")
                            .font(.title3).bold()
                        Text(healthManager.cadenceStatus)
                            .font(.title3).foregroundColor(.blue)
                    }
                    GridRow {
                        Text("Steps:")
                            .font(.title3).bold()
                        Text(healthManager.stepsStatus)
                            .font(.title3).foregroundColor(.blue)
                    }
                    GridRow {
                        Text("Distance:")
                            .font(.title3).bold()
                        Text(healthManager.distanceStatus)
                            .font(.title3).foregroundColor(.blue)
                    }
                    GridRow {
                        Text("Health Steadiness:")
                            .font(.title3).bold()
                        Text(healthManager.steadinessStatus)
                            .font(.title3).foregroundColor(.blue)
                    }
                }
                .padding(.vertical)
                
                Button(action: {
                    if healthManager.isTracking {
                        healthManager.stopSession()
                    } else {
                        healthManager.requestAuthorizationAndStart()
                    }
                }) {
                    Text(healthManager.isTracking ? "Stop Monitoring" : "Start Live Track")
                        .font(.title2).bold().foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 65)
                        .background(healthManager.isTracking ? Color.red : Color.blue)
                        .cornerRadius(50)
                }
            }
            .padding(30)
        }
        .background(Color(.systemBackground))
        .alert(isPresented: $healthManager.triggersAlert) {
            Alert(
                title: Text("Time to Rest!"),
                message: Text(healthManager.alertMessage),
                dismissButton: .default(Text("OK, I am sitting")) {
                    healthManager.triggersAlert = false
                }
            )
        }
    }
}
