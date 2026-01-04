import SwiftUI

/// 静态背景视图：无动画，用于 CPU 测试
/// 如果使用这个版本后 CPU 降下来，说明问题在动画
struct LiquidGlassBackground: View {
    var body: some View {
        ZStack {
            // Base dark/deep color
            Color.black.opacity(0.8).ignoresSafeArea()
            
            // Static Gradient Orbs (no animation)
            GeometryReader { proxy in
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.3))
                        .frame(width: 300, height: 300)
                        .blur(radius: 60)
                        .offset(x: 50, y: 25)
                    
                    Circle()
                        .fill(Color.cyan.opacity(0.3))
                        .frame(width: 300, height: 300)
                        .blur(radius: 60)
                        .offset(x: 50, y: 50)
                        
                    Circle()
                        .fill(Color.purple.opacity(0.2))
                        .frame(width: 250, height: 250)
                        .blur(radius: 50)
                        .offset(x: 150, y: 100)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }
}

