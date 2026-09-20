import SwiftUI

/// Shown once, on first launch. Onboarding lives in a one-time cover, never in
/// a persistent Home widget, and it only says what changes how people use the
/// app: what it does, how to get clips into it, and which clips work best.
struct OnboardingView: View {
    let finish: () -> Void

    @State private var page = 0
    private let pageCount = 3

    private var isLastPage: Bool { page == pageCount - 1 }

    var body: some View {
        ZStack {
            CinematicBackground()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Skip", action: finish)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                        .opacity(isLastPage ? 0 : 1)
                        .disabled(isLastPage)
                }
                .frame(height: 44)
                .padding(.horizontal, 24)

                TabView(selection: $page) {
                    WelcomePage().tag(0)
                    SharePage().tag(1)
                    SourcesPage().tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                PageIndicator(count: pageCount, current: page)
                    .padding(.bottom, 22)

                Button(action: advance) {
                    Text(isLastPage ? "Start finding scenes" : "Continue")
                        .font(.headline)
                        .foregroundStyle(Color.sceneBackground)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .prominentOnboardingButton()
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
        }
        .animation(.smooth(duration: 0.35), value: page)
        .sensoryFeedback(.selection, trigger: page)
    }

    private func advance() {
        if isLastPage {
            finish()
        } else {
            page += 1
        }
    }
}

// MARK: - Pages

private struct WelcomePage: View {
    var body: some View {
        OnboardingPage(
            title: "Find the scene behind any clip",
            message: "Share a clip or paste a link. SceneFind names the show, and when the dialogue backs it up, the exact episode and moment."
        ) {
            FocusMark()
                .frame(width: 132, height: 132)
                .shadow(color: Color.sceneCyan.opacity(0.35), radius: 36, y: 8)
        }
    }
}

private struct SharePage: View {
    var body: some View {
        OnboardingPage(
            title: "Share straight from the app",
            message: "Tap Share on a clip, then pick SceneFind in the share sheet. If it's missing, tap More and add it to your favorites."
        ) {
            HStack(spacing: 18) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color.sceneCyan)
                    .frame(width: 88, height: 88)
                    .sceneGlass(in: Circle())
                Image(systemName: "chevron.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tertiary)
                FocusMark()
                    .frame(width: 88, height: 88)
            }
            .accessibilityHidden(true)
        }
    }
}

private struct SourcesPage: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 12)
            VStack(spacing: 10) {
                Text("Video gets the best match")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text("SceneFind finds the episode from what's said in the clip.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .fixedSize(horizontal: false, vertical: true)

            SceneCard {
                VStack(alignment: .leading, spacing: 18) {
                    SourceRow(
                        symbol: "video.fill",
                        tint: .sceneGreen,
                        title: "Saved videos and screen recordings",
                        detail: "Full audio, so SceneFind can find the episode and the moment."
                    )
                    SourceRow(
                        symbol: "link",
                        tint: .sceneCyan,
                        title: "TikTok and YouTube links",
                        detail: "These usually include the audio too."
                    )
                    SourceRow(
                        symbol: "speaker.slash.fill",
                        tint: .sceneGold,
                        title: "Instagram links",
                        detail: "Instagram never shares the video itself, so these fail far more often than TikTok and can't pin the episode. Save the reel and import it instead."
                    )
                }
            }

            Text("Your first 4 identifications are free.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 24)
    }
}

private struct SourceRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: symbol, tint: tint, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OnboardingPage<Hero: View>: View {
    let title: String
    let message: String
    @ViewBuilder var hero: Hero

    var body: some View {
        VStack(spacing: 36) {
            Spacer(minLength: 0)
            hero
            VStack(spacing: 12) {
                Text(title)
                    .font(.largeTitle.bold())
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
    }
}

private struct PageIndicator: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.white : Color.white.opacity(0.25))
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}

private extension View {
    /// The one filled control on the screen. Prominent glass on iOS 26; a
    /// filled capsule below it, where tinted material would leave dark text on
    /// a dark background.
    @ViewBuilder
    func prominentOnboardingButton() -> some View {
        if #available(iOS 26, *) {
            self.buttonStyle(.glassProminent)
                .tint(Color.sceneCyan)
                .controlSize(.large)
        } else {
            self.buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(Color.sceneCyan)
                .controlSize(.large)
        }
    }
}

// MARK: - Brand mark

/// The app icon's Focus Mark, drawn as vectors so it stays sharp at any size.
/// Geometry and colours match `marketing/brand/app-icon.svg` on its 1024 grid.
struct FocusMark: View {
    private static let ground = Color(red: 7 / 255, green: 9 / 255, blue: 13 / 255)
    private static let lensFill = Color(red: 10 / 255, green: 12 / 255, blue: 18 / 255)
    private static let lensStroke = Color(red: 244 / 255, green: 247 / 255, blue: 251 / 255)
    private static let bracket = Color(red: 31 / 255, green: 199 / 255, blue: 234 / 255)
    private static let violet = Color(red: 109 / 255, green: 44 / 255, blue: 232 / 255)
    private static let magenta = Color(red: 192 / 255, green: 52 / 255, blue: 168 / 255)

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 1024
            context.scaleBy(x: scale, y: scale)

            context.fill(
                Path(roundedRect: CGRect(x: 0, y: 0, width: 1024, height: 1024), cornerRadius: 229, style: .continuous),
                with: .color(Self.ground)
            )

            context.fill(
                Path(ellipseIn: CGRect(x: 270, y: 224, width: 500, height: 500)),
                with: .color(Self.lensFill)
            )

            var magnifier = Path(ellipseIn: CGRect(x: 270, y: 224, width: 500, height: 500))
            magnifier.move(to: CGPoint(x: 344, y: 650))
            magnifier.addLine(to: CGPoint(x: 164, y: 830))
            context.stroke(
                magnifier,
                with: .color(Self.lensStroke),
                style: StrokeStyle(lineWidth: 54, lineCap: .round)
            )

            var brackets = Path()
            brackets.move(to: CGPoint(x: 154, y: 334))
            brackets.addLine(to: CGPoint(x: 154, y: 216))
            brackets.addQuadCurve(to: CGPoint(x: 216, y: 154), control: CGPoint(x: 154, y: 154))
            brackets.addLine(to: CGPoint(x: 334, y: 154))
            brackets.move(to: CGPoint(x: 870, y: 690))
            brackets.addLine(to: CGPoint(x: 870, y: 808))
            brackets.addQuadCurve(to: CGPoint(x: 808, y: 870), control: CGPoint(x: 870, y: 870))
            brackets.addLine(to: CGPoint(x: 690, y: 870))
            context.stroke(
                brackets,
                with: .color(Self.bracket),
                style: StrokeStyle(lineWidth: 46, lineCap: .round, lineJoin: .round)
            )

            var play = Path()
            play.move(to: CGPoint(x: 434, y: 352))
            play.addLine(to: CGPoint(x: 714, y: 478))
            play.addLine(to: CGPoint(x: 434, y: 629))
            play.closeSubpath()
            let gradient = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [Self.violet, Self.magenta]),
                startPoint: CGPoint(x: 434, y: 352),
                endPoint: CGPoint(x: 714, y: 629)
            )
            context.fill(play, with: gradient)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
