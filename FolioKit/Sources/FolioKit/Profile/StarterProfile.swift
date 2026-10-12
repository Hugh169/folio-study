import Foundation

extension Profile {
    /// The five sample subjects with their descriptions, aliases and topic words,
    /// plus common document types and exams. A starting point the student edits.
    public static func starter() -> Profile {
        Profile(
            subjects: [
                Subject(
                    name: "Mathematics",
                    colorHex: 0x0A84FF,
                    aliases: ["Maths", "Math", "Mathematics Advanced", "Mathematics Standard", "Mathematics Extension", "Further Maths", "Mathématiques", "Matemáticas"],
                    summary: "Algebra, calculus, functions, trigonometry, statistics, probability, geometry and vectors",
                    keywords: ["calculus", "derivative", "differentiate", "differentiation", "integral", "integrate", "integration", "algebra", "equation", "inequality", "quadratic", "polynomial", "parabola", "gradient", "intercept", "trigonometry", "trigonometric", "sine rule", "cosine rule", "radian", "probability", "statistics", "standard deviation", "interquartile range", "median", "binomial", "vector", "matrix", "logarithm", "exponential", "theorem", "proof by induction", "geometry", "arithmetic sequence", "geometric series", "stationary point", "simultaneous equations", "dérivée", "fonction", "derivada", "index laws", "log laws", "logarithm laws", "laws of logarithms", "exponent laws", "law of sines", "law of cosines", "De Morgan's laws"]
                ),
                Subject(
                    name: "English",
                    colorHex: 0xFF9F0A,
                    aliases: ["English Advanced", "English Standard", "English Extension", "English Literature", "English Language", "Literature"],
                    summary: "Literature and language: novels, poetry, drama, Shakespeare, essays, creative writing and analysing texts",
                    keywords: ["poem", "poetry", "poet", "novel", "novella", "short story", "memoir", "fiction", "Gothic", "Shakespeare", "Macbeth", "Hamlet", "Othello", "Romeo", "Orwell", "Dickens", "Austen", "playwright", "protagonist", "metaphor", "simile", "imagery", "symbolism", "personification", "alliteration", "hyperbole", "juxtaposition", "allusion", "allegory", "satire", "tragedy", "soliloquy", "narrator", "narrative voice", "stanza", "sonnet", "iambic pentameter", "rhetoric", "persuasive", "thesis", "literary techniques", "language techniques", "creative writing", "close reading", "characterisation", "dramatic irony", "prescribed text"]
                ),
                Subject(
                    name: "Physics",
                    colorHex: 0x40C8E0,
                    aliases: ["Physique", "Física", "Physique-Chimie"],
                    summary: "Motion, forces, energy, waves, electricity, magnetism, light and quantum physics",
                    keywords: ["velocity", "acceleration", "displacement", "force", "momentum", "impulse", "inertia", "projectile", "kinematics", "gravitational", "orbit", "satellite", "circuit", "voltage", "resistor", "resistance", "Ohm", "electric field", "magnetic field", "electromagnetic", "motor effect", "transformer", "wavelength", "frequency", "oscillation", "pendulum", "Doppler", "photon", "quantum", "relativity", "friction", "torque", "kinetic energy", "potential energy", "refraction", "photoelectric", "luminosity", "astrophysics", "newton's laws", "vitesse", "fuerza", "onda", "Newton's first law", "Newton's second law", "Newton's third law", "laws of motion", "Ohm's law", "Hooke's law", "Snell's law", "Faraday's law", "Lenz's law", "Coulomb's law", "Kepler's laws", "law of conservation of energy", "inverse square law"]
                ),
                Subject(
                    name: "Chemistry",
                    colorHex: 0xBF5AF2,
                    aliases: ["Chem", "Chimie", "Química"],
                    summary: "Atoms, bonding, reactions, stoichiometry, acids and bases, equilibrium and organic chemistry",
                    keywords: ["mole", "molar", "molecule", "reaction", "acid", "base", "pH", "buffer", "neutralisation", "indicator", "equilibrium", "titration", "burette", "organic", "alkane", "alkene", "alcohol", "carboxylic acid", "hydrocarbon", "ester", "polymer", "functional group", "IUPAC", "covalent", "ionic", "Lewis", "VSEPR", "intermolecular", "periodic table", "compound", "oxidation", "reduction", "redox", "electrochemistry", "galvanic", "electrolysis", "anode", "cathode", "catalyst", "enthalpy", "calorimetry", "stoichiometry", "limiting reagent", "concentration", "precipitate", "solubility", "isotope", "radioisotope", "electron configuration", "combustion", "réaction", "ácido", "enlace", "Hess's law", "Boyle's law", "Charles's law", "Charles' law", "ideal gas law", "Avogadro's law", "rate law", "law of conservation of mass"]
                ),
                Subject(
                    name: "History",
                    colorHex: 0xFF6482,
                    aliases: ["Modern History", "Ancient History", "History Extension", "Histoire", "Historia"],
                    summary: "Past societies, wars, revolutions, empires, political movements and historical sources",
                    keywords: ["war", "revolution", "empire", "emperor", "monarchy", "republic", "treaty", "dynasty", "civilisation", "ancient", "archaeological", "historian", "historiography", "interpretation", "primary source", "source analysis", "colonial", "colony", "colonisation", "independence", "constitution", "parliament", "suffrage", "dictator", "dictatorship", "regime", "fascism", "communism", "nationalism", "Cold War", "World War", "Great Depression", "Wall Street Crash", "Versailles", "Nazi", "Hitler", "Weimar", "Soviet", "Stalin", "Lenin", "Bolshevik", "Roman", "pharaoh", "medieval", "Gallipoli", "Industrial Revolution", "civil rights", "slavery", "enslaved", "abolition", "plantation", "apartheid", "genocide", "Holocaust", "propaganda", "guerre", "révolution", "guerra"]
                ),
            ],
            documentTypes: [
                DocumentType(name: "Past Papers", aliases: ["past paper", "exam paper", "examination", "trial exam", "trial paper", "specimen paper", "mock exam", "question paper", "paper 1", "paper 2", "paper 3", "reading time", "working time", "time allowed", "instructions to candidates", "total marks", "marking guidelines", "mark scheme", "épreuve", "sujet", "examen"]),
                DocumentType(name: "Notes", aliases: ["notes", "summary", "revision", "study notes", "class notes", "lecture notes"]),
                DocumentType(name: "Worksheets", aliases: ["worksheet", "exercises", "handout", "problem set", "activity sheet"]),
                DocumentType(name: "Essays", aliases: ["essay", "essay draft", "extended response", "draft"]),
                DocumentType(name: "Assignments", aliases: ["assignment", "assessment task", "project", "rubric", "due date"]),
                DocumentType(name: "Practicals", aliases: ["practical", "prac", "experiment", "lab report", "investigation", "hypothesis"]),
                DocumentType(name: "Practice", aliases: ["practice", "practice set", "practice questions", "revision questions"]),
                DocumentType(name: "Sources", aliases: ["source", "sources", "primary source", "secondary source", "source analysis"]),
                DocumentType(name: "Slides", aliases: ["slides", "presentation", "lecture slides", "learning intentions", "learning goals"]),
            ] + mediaDocumentTypes,
            examBoards: [
                ExamBoard(name: "HSC", aliases: ["Higher School Certificate", "NESA"]),
                ExamBoard(name: "GCSE", aliases: ["General Certificate of Secondary Education"]),
                ExamBoard(name: "A Level", aliases: ["A-Level", "GCE A Level", "AS Level"]),
                ExamBoard(name: "IB", aliases: ["International Baccalaureate", "IB Diploma", "IBDP"]),
                ExamBoard(name: "IGCSE", aliases: ["Cambridge IGCSE"]),
                ExamBoard(name: "VCE", aliases: ["Victorian Certificate of Education"]),
                ExamBoard(name: "AP", aliases: ["Advanced Placement", "AP Exam"]),
                ExamBoard(name: "Baccalauréat", aliases: ["Baccalaureat", "Bac général"]),
                ExamBoard(name: "AQA"),
                ExamBoard(name: "Edexcel", aliases: ["Pearson Edexcel"]),
                ExamBoard(name: "OCR"),
            ],
            defaultDocumentType: "Notes"
        )
    }

    /// For university: no starter subjects (courses come from the student or
    /// their timetable), university kinds of document, and no exam boards.
    public static func university() -> Profile {
        Profile(
            subjects: [],
            documentTypes: [
                DocumentType(name: "Lectures", aliases: ["lecture", "lectures", "lecture slides", "lecture notes", "lec"]),
                DocumentType(name: "Tutorials", aliases: ["tutorial", "tute", "tutorial sheet", "tutorial questions", "problem set", "workshop"]),
                DocumentType(name: "Labs", aliases: ["lab", "laboratory", "lab sheet", "lab report", "practical", "prac"]),
                DocumentType(name: "Readings", aliases: ["reading", "readings", "journal article", "chapter", "case study", "abstract", "doi"]),
                DocumentType(name: "Assignments", aliases: ["assignment", "assessment", "assessment task", "project", "rubric", "marking criteria", "submission", "due date"]),
                DocumentType(name: "Exams", aliases: ["exam", "final exam", "past exam", "sample exam", "practice exam", "midterm", "mid-semester", "exam paper"]),
                DocumentType(name: "Notes", aliases: ["notes", "summary", "revision", "study notes"]),
            ] + mediaDocumentTypes,
            examBoards: [],
            defaultDocumentType: "Notes",
            level: .university,
            studyPreferences: .university
        )
    }

    /// Recordings and videos get folders of their own, whatever they say.
    static let mediaDocumentTypes = [
        DocumentType(name: "Recordings", aliases: ["recording", "voice memo"], fileKinds: ["public.audio"]),
        DocumentType(name: "Videos", aliases: ["lesson video", "lecture video"], fileKinds: ["public.movie"]),
    ]
}
