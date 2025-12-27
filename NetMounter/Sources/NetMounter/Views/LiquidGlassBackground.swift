import SwiftUI

struct LiquidGlassBackground: View {
    @State private var animate = false
    
    var body: some View {
        ZStack {
            // Base dark/deep color
            Color.black.opacity(0.8).ignoresSafeArea()
            
            // Animated Gradient Orbs
            GeometryReader { proxy in
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.3))
                        .frame(width: 300, height: 300)
                        .blur(radius: 60)
                        .offset(x: animate ? -50 : 150, y: animate ? -50 : 100)
                    
                    Circle()
                        .fill(Color.cyan.opacity(0.3))
                        .frame(width: 300, height: 300)
                        .blur(radius: 60)
                        .offset(x: animate ? 200 : -100, y: animate ? 200 : -100)
                        
                    Circle()
                        .fill(Color.purple.opacity(0.2))
                        .frame(width: 250, height: 250)
                        .blur(radius: 50)
                        .offset(x: animate ? 50 : 250, y: animate ? 150 : 50)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 10).repeatForever(autoreverses: true)) {
                animate.toggle()
            }
        }
    }
}
